import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, resolve } from 'node:path'
import vm from 'node:vm'
import { parse, compileScript } from '@vue/compiler-sfc'
import ts from 'typescript'
import * as vue from 'vue'

const root = resolve(import.meta.dirname, '..')

// Execute the real component's series construction; only the chart renderer and
// DOM lifecycle are replaced so these tests need no browser or task database.
function chartFixture(props) {
  let option
  const cache = new Map()
  const scope = vue.effectScope()
  const chart = { setOption(value) { option = value }, resize() {}, dispose() {} }
  function load(filename) {
    if (cache.has(filename)) return cache.get(filename)
    let source = readFileSync(filename, 'utf8')
    if (filename.endsWith('.vue')) {
      source = compileScript(parse(source, { filename }).descriptor, { id: 'energy-flow-test' }).content
    }
    const code = ts.transpileModule(source, {
      compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
    }).outputText
    const module = { exports: {} }
    const nativeRequire = createRequire(filename)
    const context = vm.createContext({
      ...vue, module, exports: module.exports, console, performance,
      onMounted() {}, onBeforeUnmount() {},
      require(id) {
        if (id === 'echarts') return { init: () => chart }
        if (id.startsWith('~~/')) return load(resolve(root, `${id.slice(3)}.ts`))
        if (id.startsWith('.')) return load(resolve(dirname(filename), `${id}.ts`))
        return nativeRequire(id)
      },
    })
    vm.runInContext(code, context, { filename })
    cache.set(filename, module.exports)
    return module.exports
  }
  const component = load(resolve(root, 'app/components/EnergyFlowChart.vue')).default
  const state = scope.run(() => component.setup(props, { expose() {}, emit() {} }))
  state.chartRef.value = {}
  return {
    render() { state.renderChart(); return option },
    close() { scope.stop() },
  }
}

for (const [medium, loadType, sourceType, storageType, label] of [
  ['E', 'ELOAD', 'PV', 'ES', '电负荷'],
  ['H', 'HLOAD', 'ET', 'HS', '氢负荷'],
  ['Q', 'QLOAD', 'CHP', 'TES', '热负荷'],
]) {
  test(`${label}: aggregate multiple loads, retain charging sinks and missing-data gaps`, () => {
    const points = values => values.map(([ts, value]) => ({ ts, value }))
    const props = vue.reactive({
      busLabel: `${medium} bus`, layerId: '1', displayMode: 'balance', timeStepMinutes: 60,
      simStartTime: '0:00', simEndTime: '3:00',
      displayWindow: { dateStart: 0, dateEnd: 180, start: 0, end: 180 },
      codeToLabel: { src: '供给设备', a: '负荷一', b: '负荷二', store: '储能' },
      variables: [`${medium}_${sourceType}_out_src`, `${medium}_${loadType}_in_a`,
        `${medium}_${loadType}_in_b`, `${medium}_${storageType}_in_store`],
      liveData: {
        [`${sourceType}|${medium}_${sourceType}_src`]: { '1': points([['0:00', 30], ['1:00', 30], ['2:00', 30]]) },
        [`${loadType}|${medium}_${loadType}_a`]: { '1': points([['0:00', 10], ['1:00', -15]]) },
        [`${loadType}|${medium}_${loadType}_b`]: { '1': points([['0:00', 5]]) },
        [`${storageType}|${medium}_${storageType}_in_store`]: { '1': points([['0:00', 7], ['1:00', 8]]) },
      },
    })
    const fixture = chartFixture(props)
    try {
      const balance = fixture.render()
      assert.equal(balance.series.length, 4)
      assert.ok(balance.series.every(series => series.type === 'bar'))
      assert.deepEqual(Array.from(balance.series[1].data), [-10, -15, 0])

      props.displayMode = 'loadTracking'
      const tracking = fixture.render()
      const line = tracking.series.find(series => series.type === 'line')
      assert.equal(line.name, label)
      assert.deepEqual(Array.from(line.data), [15, 15, null])
      assert.equal(line.connectNulls, false)
      assert.equal(tracking.series.filter(series => series.type === 'bar').length, 2)
      assert.deepEqual(Array.from(tracking.series[1].data), [-7, -8, 0])
      assert.ok(tracking.legend.data.some(item => item.name === label && item.icon))
    }
    finally { fixture.close() }
  })
}

test('a bus without a recognized load retains all sinks in tracking mode', () => {
  const fixture = chartFixture({
    busLabel: '氢总线', layerId: '1', displayMode: 'loadTracking', timeStepMinutes: 60,
    variables: ['H_HS_in_store'], codeToLabel: { store: '储氢罐' },
    liveData: { 'HS|H_HS_in_store': { '1': [{ ts: '0:00', value: 9 }] } },
    displayWindow: { dateStart: 0, dateEnd: 60, start: 0, end: 60 },
  })
  try {
    const option = fixture.render()
    assert.equal(option.series.length, 1)
    assert.equal(option.series[0].type, 'bar')
    assert.deepEqual(Array.from(option.series[0].data), [-9])
  }
  finally { fixture.close() }
})
