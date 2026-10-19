import type { DocChapter } from './types'

export const chapter2: DocChapter = {
  id: 'ch2',
  title: '第二章 · 设备模型',
  summary: '各类设备的输入输出、决策变量、约束、目标函数与可选配置',
  sections: [
    {
      id: 'ch2-general',
      title: '2.1 通用约定',
      blocks: [
        {
          type: 'p',
          text: '所有设备模型共享同一套工程约定。读懂本节后，后续各设备只需关注差异。'
        },
        {
          type: 'h',
          level: 3,
          text: '符号与单位'
        },
        {
          type: 'list',
          items: [
            't ∈ {1,…,T}，T = length / step；Δt = step 小时数。',
            'E_x[t]：设备 x 在时段 t 的能量/功率变量；C：额定容量。',
            '后端内部统一 kW / kWh / h；界面与接口同口径。',
            '成本能量类费率解析时 ×Δt；启停成本 on_off_cost 为元/次，不乘 Δt。',
            '时层参数写在 layer.paras / layer.constraints / layer.objectives，可按层不同。'
          ]
        },
        {
          type: 'h',
          level: 3,
          text: '模型文件分层'
        },
        {
          type: 'table',
          headers: ['文件', '职责'],
          rows: [
            ['component-library.json', '参数 schema：字段、类型、默认值、范围、开关（前后端共用）'],
            ['component.jl', '组件数据结构与注册'],
            ['model-common.jl', '参数解析 resolve_*_params() 与共享数学函数'],
            ['model-base.jl', '原始数学原理（人读 / 验证）'],
            ['model.jl', 'JuMP 建模 + CodeTracer 代码追踪（生产）'],
            ['flexibility.jl', '该设备的灵活性计算口径'],
            ['validation.jl', '参数与模型校验']
          ]
        },
        {
          type: 'h',
          level: 3,
          text: '运行模式（mode）'
        },
        {
          type: 'table',
          headers: ['模式', '含义', '当前层如何建模'],
          rows: [
            ['stand_alone 独立运行', '本层完全自由优化', '是'],
            ['disabled 禁用', '本层不参与', '否（变量锁 0）'],
            ['fixed_state 固定状态', '尊重上层开停/充放状态，当前层出力自由', '是'],
            ['adjust_power 调节计划', '在上层计划附近 ±δ 调节', '是'],
            ['full_follow 完全跟随', '严格跟随上层计划（bounds 锁定）', '是（变量被固定）']
          ]
        },
        {
          type: 'h',
          level: 3,
          text: '约束 / 目标开关'
        },
        {
          type: 'p',
          text: '每类约束和目标都有开关（如 ramp_constraint_on、curtailment_constraint_on、om_objective_on）。未启用的约束不进模型，未启用的目标不进目标函数。前端表单由组件库 schema 自动生成。'
        },
        {
          type: 'h',
          level: 3,
          text: '目标函数骨架'
        },
        {
          type: 'formula',
          text: 'min  Z = Σ_设备  ( 目标开关 × 单价 × 对应量 )  +  ρ × Σ (SHORTAGE + EXCESS)',
          caption: '设备通过 @expression 注册命名成本项，由 CodeTracer 汇入 @objective'
        },
        {
          type: 'h',
          level: 3,
          text: '能量平衡（总线）'
        },
        {
          type: 'formula',
          text: 'Σ_i s_i · P_i(t) + SHORTAGE(t) − EXCESS(t) = 0\nSHORTAGE ≤ M·γ,  EXCESS ≤ M·(1−γ)     （互斥，M=1e8）',
          caption: '电/热/氢总线逐时段平衡；s_i：注入 +1、提取 −1'
        },
        {
          type: 'callout',
          tone: 'tip',
          title: '松弛变量怎么用',
          text: '启用松弛后，平衡允许缺供（SHORTAGE）或过剩（EXCESS），目标中乘高惩罚。结果里 SHORTAGE>0 = 该时段供电不足；EXCESS>0 = 有弃能/弃电。关松弛则严格平衡，数据不合理时可能无解。'
        }
      ]
    },
    {
      id: 'ch2-wt',
      title: '2.2 风机（WT）',
      blocks: [
        {
          type: 'p',
          text: '风电机组将风能转换为电能。可用功率由风速边界与功率曲线决定；优化变量是实际出力与弃风功率。仅支持 stand_alone / disabled。'
        },
        {
          type: 'h',
          level: 3,
          text: '输入 / 输出'
        },
        {
          type: 'table',
          headers: ['类别', '内容'],
          rows: [
            ['输入（边界）', '风速 / factor / power；可选机型拟合曲线'],
            ['主要参数', 'capacity、efficiency、切入/额定/切出风速、参考/轮毂高度、风切变指数、传动/发电机/逆变器效率、ramp'],
            ['决策变量', 'E_WT[t] 出力；E_WT_cut[t] 弃风'],
            ['输出', '电总线注入；成本 C_wt_om、C_wt_cut']
          ]
        },
        {
          type: 'h',
          level: 3,
          text: '可用功率（风速边界）'
        },
        {
          type: 'formula',
          text: 'v_scaled = |v| × (h2/h1)^α\n\nc(v) = 0                           v < v_in\n     = (v³−v_in³)/(v_r³−v_in³)    v_in ≤ v < v_r\n     = 1                           v_r ≤ v < v_out\n     = 0                           v ≥ v_out\n\nP_av = c × η_t × η_g × η_inv × capacity',
          caption: '三次方功率曲线 + 高度修正；factor 边界：P_av = clamp(f,0,1)×C；power 边界：P_av = |P|'
        },
        {
          type: 'h',
          level: 3,
          text: '约束与目标'
        },
        {
          type: 'formula',
          text: 'E_WT[t] + E_WT_cut[t] = P_av[t]\n∑ E_WT_cut ≤ max_cut_ratio × ∑ P_av        （可开关）\n| E_WT_cut[t+1] − E_WT_cut[t] | ≤ R×C×Δt   （可开关）\n\nZ_WT = om_cost × ∑ E_WT  +  cut_cost × ∑ E_WT_cut',
          caption: '只约束弃电的主动变化，自然可用功率变化属外生'
        },
        {
          type: 'list',
          items: [
            'max_cut_ratio：最大弃风比例（默认 1.0）。',
            'curtailment_constraint_on / ramp_constraint_on：弃风上限、主动变化率（默认 true / false）。',
            'om_objective_on / cut_objective_on：运维、弃风成本（默认均开）。',
            '默认：capacity=300000 kW，efficiency=0.95，v_in/v_r/v_out=3/9.5/19.5 m/s，om_cost=0.1、cut_cost=0.9 元/kWh。'
          ]
        }
      ]
    },
    {
      id: 'ch2-pv',
      title: '2.3 光伏（PV）',
      blocks: [
        {
          type: 'p',
          text: '光伏将辐照转换为电能，结构与风机对称。仅 stand_alone / disabled。'
        },
        {
          type: 'formula',
          text: '辐照边界：P_av = clamp(G/1000, 0, 1) × η × capacity     （G_ref = 1000 W/m²）\nE_PV[t] + E_PV_cut[t] = P_av[t]\n∑ E_PV_cut ≤ max_cut_ratio × ∑ P_av\n\nZ_PV = om_cost × ∑ E_PV + cut_cost × ∑ E_PV_cut',
          caption: 'factor / power / 拟合曲线边界与风机同口径'
        },
        {
          type: 'list',
          items: [
            '默认：capacity=300000 kW，efficiency=0.95，om_cost=0.1、cut_cost=0.9 元/kWh。',
            '开关同 WT：弃光上限、主动变化率、运维/弃光目标。'
          ]
        }
      ]
    },
    {
      id: 'ch2-cp',
      title: '2.4 燃煤机组（CP）',
      blocks: [
        {
          type: 'p',
          text: '燃煤机组是典型可控电源：出力受容量、爬坡、最低出力、最小启停时间约束，可参与机组组合。支持 stand_alone / adjust_power / fixed_state / full_follow / disabled。'
        },
        {
          type: 'h',
          level: 3,
          text: '决策变量'
        },
        {
          type: 'table',
          headers: ['变量', '含义', '范围'],
          rows: [
            ['E_CP[t]', '电出力', '0 ~ C'],
            ['F_CP[t]', '燃料量', '与出力经效率耦合'],
            ['ΔE_CP[t]', '爬坡量', '−R·C·Δt ~ +R·C·Δt'],
            ['γ / γ_start / γ_stop', '开机 / 启 / 停', '0/1'],
            ['δ / δ_up / δ_down', '调节方向 / 上下调', '调节模式']
          ]
        },
        {
          type: 'h',
          level: 3,
          text: '核心约束'
        },
        {
          type: 'formula',
          text: 'E[t] = F[t] × η\nE[t] ≤ γ[t] × C\nE[t] ≥ min × C   或   E[t] ≥ γ[t] × min × C\nΔE[t] = E[t+1] − E[t],  |ΔE| ≤ R×C×Δt\nγ[t] − γ[t−1] = start[t] − stop[t],  start+stop ≤ 1\n∑_{h=t−Ton+1}^{t} start[h] ≤ γ[t]\n∑_{h=t−Toff+1}^{t} stop[h] ≤ 1 − γ[t]\nE[t] = P_plan[t] + δ_up[t] − δ_down[t]          （调节模式）',
          caption: 'C1 燃料转换、C2 爬坡、C3 最低出力、C4–C9 启停、C10–C11 调节'
        },
        {
          type: 'h',
          level: 3,
          text: '目标与参数'
        },
        {
          type: 'formula',
          text: 'Z_CP = om_cost × ∑ E[t]\n      + on_off_cost × ∑ (start[t] + stop[t])\n      + adjust_cost × ∑ (δ_up[t] + δ_down[t])',
          caption: '启停成本为元/次，不乘 Δt'
        },
        {
          type: 'list',
          items: [
            '开关：ramp / min / on_off / adjust 约束；om / on_off / adjust 目标。',
            '默认：capacity=350000 kW，η=0.5，ramp=0.5（1/h），min=0.3，T_min_on/off=10h，om_cost=0.1，on_off_cost=10000 元/次，adjust_cost=0.15 元/kWh。'
          ]
        }
      ]
    },
    {
      id: 'ch2-gp-chp',
      title: '2.5 气电机组（GP）与热电联产（CHP）',
      blocks: [
        {
          type: 'p',
          text: '气电与燃煤数学同构，仅参数不同。CHP 在电出力之外按固定热电比产出热。'
        },
        {
          type: 'formula',
          text: 'GP：E_GP[t] = F_GP[t] × η_e，约束同燃煤\nCHP：E_CHP[t] = F_CHP[t] × η_e\n     Q_CHP[t] = E_CHP[t] × β          （固定热电比）',
          caption: 'CHP 同时向电总线与热总线注入'
        },
        {
          type: 'list',
          items: [
            'GP 默认：capacity=450000 kW，η=0.55，ramp=0.6，min=0.2，T_min_on/off=4/8 h，om=0.08，on_off=5000 元/次。',
            'CHP 默认：capacity=340000 kW（电），η_e=0.4，β=0.5，om=0.08，on_off=8000 元/次。',
            'full_follow 时 CHP 的 Q 由 E 反算。'
          ]
        }
      ]
    },
    {
      id: 'ch2-es',
      title: '2.6 电化学储能（ES）',
      blocks: [
        {
          type: 'p',
          text: '电池储能通过充放电实现能量时移。SOC 遵循能量守恒；充放互斥；可设爬坡、SOC 上下限与首末相等。'
        },
        {
          type: 'h',
          level: 3,
          text: '决策变量'
        },
        {
          type: 'table',
          headers: ['变量', '含义', '范围'],
          rows: [
            ['E_ES[t]', '荷电量 SOC', '0 ~ max×C'],
            ['E_in[t] / E_out[t]', '充电 / 放电功率', '0 ~ ramp×C'],
            ['γ_ES[t]', '充放状态', '0/1 或三值']
          ]
        },
        {
          type: 'h',
          level: 3,
          text: '核心公式'
        },
        {
          type: 'formula',
          text: 'E[t] = E[t−1]×(1−loss_step) + (E_in[t−1]×η − E_out[t−1]/η) × Δt\nE[t] ≥ min × C,   E[t] ≤ max × C\nE_in[t] ≤ ramp × C,   E_out[t] ≤ ramp × C\nE_in[t] ≤ M·γ[t],   E_out[t] ≤ M·(1−γ[t])     （充放互斥）\nE[first] = ini × C 或数据库初值\nE[first] = E[last]                              （首末相等，可开关）',
          caption: 'loss_step = 1 − (1−loss)^Δt；ramp 为倍率，倍率 × 能量容量 = 功率上限'
        },
        {
          type: 'formula',
          text: 'Z_ES = om_cost × ∑ (E_in + E_out) + adjust_cost × ∑ (δ_up + δ_down)',
          caption: '运维按吞吐量计'
        },
        {
          type: 'list',
          items: [
            '开关：ramp / min / adjust / start_end_equality 约束；om / adjust 目标。',
            '默认：capacity=200000 kWh，η=0.95，ramp=0.5，max/min/ini=1.0/0.1/0.1，loss=0.001/h。'
          ]
        }
      ]
    },
    {
      id: 'ch2-other-storage',
      title: '2.7 其他储能：飞轮 / 抽蓄 / 压缩空气 / 储氢',
      blocks: [
        {
          type: 'p',
          text: '骨架与电化学储能一致：状态变量 + 充/放功率 + 能量守恒 + 上下限；差异在介质与参数。'
        },
        {
          type: 'table',
          headers: ['设备', '介质', '关键差异'],
          rows: [
            ['飞轮 FS', '电 / 动能', '小容量（默认 500 kWh）、高倍率（ramp=0.95）、损耗较大（0.02/h）'],
            ['抽蓄 PS', '水库势能', '功率容量 capacity 与能量容量 storage_capacity 分离；爬坡约束在净功率 P_out−P_in 上'],
            ['压缩空气 CS', '压缩空气', '默认 500000 kWh，η=0.7，ramp=0.3，寿命长'],
            ['储氢 HS', '氢气（kg）', '质量域；capacity=50000 kg，om_cost 单位元/kg；接氢总线']
          ]
        },
        {
          type: 'formula',
          text: '通用：X[t] = X[t−1]×(1−loss) + (充×η_c − 放/η_d)×Δt\nPS 爬坡：|Δ(P_out − P_in)| ≤ ramp × C × Δt',
          caption: '各设备按自身单位实例化'
        }
      ]
    },
    {
      id: 'ch2-hydro',
      title: '2.8 常规水电（HYDRO）',
      blocks: [
        {
          type: 'p',
          text: '首版为可调发电单元（不做库容耦合），按分时可用出力边界与爬坡运行。'
        },
        {
          type: 'formula',
          text: 'MIN[t] ≤ E_HYDRO[t] ≤ AVAIL[t]\nMIN[t] = min × AVAIL[t]\n| E[t+1] − E[t] | ≤ ramp × C × Δt          （ramp_constraint_on 默认开）\n\nZ = om_cost × ∑ E_HYDRO',
          caption: 'AVAIL 来自水情/边界；若边界已含同尺度爬坡限制，可关 ramp 约束避免重复'
        },
        {
          type: 'list',
          items: [
            '默认：capacity=100000 kW，ramp=0.5，min=0.1，om_cost=0.05 元/kWh。',
            '模式：stand_alone / disabled。'
          ]
        }
      ]
    },
    {
      id: 'ch2-et',
      title: '2.9 电解槽（ET）',
      blocks: [
        {
          type: 'p',
          text: '电解槽用电制氢：电侧提取、氢侧注入。效率描述电—氢转换。'
        },
        {
          type: 'formula',
          text: 'H_ET[t] = E_ET[t] × η\n0 ≤ E_ET[t] ≤ C\n| E[t+1] − E[t] | ≤ R×C×Δt\n\nZ = om_cost × ∑ E_ET + on_off_cost × 启停 + adjust_cost × 调节',
          caption: '爬坡/最低出力/启停/调节约束与火电同构（作用在耗电功率上）'
        },
        {
          type: 'list',
          items: [
            '默认：capacity=100000 kW，η=0.7，ramp=0.5，min=0.1，T_min_on/off=2/1 h。',
            '运维成本按耗电功率计；向氢总线注入 H_ET。'
          ]
        }
      ]
    },
    {
      id: 'ch2-loads',
      title: '2.10 负荷（ELOAD / HLOAD / QLOAD）',
      blocks: [
        {
          type: 'p',
          text: '分时电/氢/热负荷从边界读取需求曲线，一般为刚性负荷（由边界锁定，不参与优化决策），不参与经济计算。'
        },
        {
          type: 'table',
          headers: ['类型', '介质', '默认 rated_demand', '边界'],
          rows: [
            ['ELOAD', '电', '150000 kW', 'load'],
            ['HLOAD', '氢', '5000 kg/h（纯度 0.9999）', 'load'],
            ['QLOAD', '热', '100000 kW', 'load']
          ]
        },
        {
          type: 'formula',
          text: '刚性：E[t] ∈ [data[t], data[t]+1]     （由边界数据锁定，+1 为数值容差）',
          caption: 'stand_alone 模式；disabled 时锁 [0,1]'
        }
      ]
    },
    {
      id: 'ch2-grid-bus',
      title: '2.11 电网（GRID）与总线（BUS）',
      blocks: [
        {
          type: 'p',
          text: '电网是系统与外部的功率交换边界（POI），不是内部资源。正 P_POI 上送、负购电；停用即离网。总线承载电/热/氢平衡。'
        },
        {
          type: 'h',
          level: 3,
          text: '电网变量与目标'
        },
        {
          type: 'formula',
          text: 'E_in[t]  ∈ [0, C × sell_ratio]     上送（售电）\nE_out[t] ∈ [0, C × buy_ratio]      购入（购电）\nP_POI = E_in − E_out\n\nC_grid = ∑ ( E_out × buy_price − E_in × sell_price )',
          caption: '购电正成本、售电负收益；默认 capacity=1000000 kW，buy/sell_ratio=1.0，电价 0.5/0.4 元/kWh'
        },
        {
          type: 'h',
          level: 3,
          text: '总线平衡符号规则'
        },
        {
          type: 'table',
          headers: ['组件', '注入 (+1)', '提取 (−1)'],
          rows: [
            ['WT / PV / CP / GP / CHP / HYDRO', '发电', ''],
            ['ET / ELOAD / HLOAD / QLOAD', '', '耗电 / 耗氢 / 耗热'],
            ['ES / FS / CS / PS', '放电 / 发电', '充电 / 抽水'],
            ['GRID', '购入', '上送'],
            ['CHP 供热 / ET 产氢 / HS', '热 +1 / 氢 +1', '充氢 −1']
          ]
        },
        {
          type: 'list',
          items: [
            'ELEC_BUS / THERMAL_BUS / H2_BUS：按端口连接自动生成平衡。',
            '松弛 SHORTAGE / EXCESS 挂在总线上，惩罚进总目标。'
          ]
        }
      ]
    },
    {
      id: 'ch2-economy',
      title: '2.12 成本项与目标汇总',
      blocks: [
        {
          type: 'p',
          text: '各设备通过命名表达式注册成本，汇总为最小化总成本。经济性评价按设备与成本项做构成分析，支持运行中动态刷新。'
        },
        {
          type: 'table',
          headers: ['成本项', '计价对象', '单位口径', '开关'],
          rows: [
            ['om_cost 运维', '出力或吞吐 × Δt', '元/kWh', 'om_objective_on'],
            ['cut_cost 弃风/弃光', '弃电量 × Δt', '元/kWh', 'cut_objective_on'],
            ['on_off_cost 启停', '启停次数', '元/次（不乘 Δt）', 'on_off_objective_on'],
            ['adjust_cost 调节', '调节量 × Δt', '元/kWh', 'adjust_objective_on'],
            ['purchase_cost 购电', '购电 × 买价 × Δt', '元/kWh', 'exchange_objective_on'],
            ['sell_revenue 售电', '−售电 × 卖价 × Δt', '元/kWh', 'exchange_objective_on'],
            ['slack 惩罚', 'SHORTAGE+EXCESS', '算法配置 ρ', 'slackEnabled']
          ]
        },
        {
          type: 'p',
          text: '派生指标：净成本、目标函数值、日均成本、月/年估算、按成本项分解、是否部分完成。负荷类不参与经济计算。'
        },
        {
          type: 'callout',
          tone: 'info',
          title: '如何读懂目标',
          text: '结果页经济性评价按设备/成本项拆开 Z。某成本项开关关闭则不进最优解构成；使用松弛时惩罚项单独列出，提示边界或容量存在缺供/过剩。'
        }
      ]
    },
    {
      id: 'ch2-summary',
      title: '2.13 设备总表',
      blocks: [
        {
          type: 'table',
          headers: ['代码', '名称', '类别', '主要输入', '主要变量 / 输出'],
          rows: [
            ['WT', '风机', '新能源', '风速', 'E_WT, E_WT_cut'],
            ['PV', '光伏', '新能源', '辐照', 'E_PV, E_PV_cut'],
            ['CP', '燃煤机组', '常规电源', '参数/计划', 'E_CP, F_CP, 启停'],
            ['GP', '气电机组', '常规电源', '参数/计划', 'E_GP, 燃料'],
            ['CHP', '热电联产', '常规电源', '参数/计划', 'E_CHP, Q_CHP'],
            ['HYDRO', '常规水电', '常规电源', '分时出力边界', 'E_HYDRO'],
            ['GRID', '电网 POI', '外部系统', '接口限值/电价', 'P_POI, 购售电'],
            ['ES', '电化学储能', '储能', '参数', 'E_ES, 充/放'],
            ['FS', '飞轮储能', '储能', '参数', '状态, 充/放'],
            ['PS', '抽水蓄能', '储能', '参数', '库容, 抽/发（净功率爬坡）'],
            ['CS', '压缩空气储能', '储能', '参数', '压力, 充/发'],
            ['HS', '储氢罐', '储能', '参数', '氢量, 充/放氢'],
            ['ET', '电解槽', '转换', '用电', '产氢 H_ET'],
            ['ELOAD', '分时电负荷', '负荷', '负荷曲线', '电提取'],
            ['HLOAD', '分时氢负荷', '负荷', '负荷曲线', '氢提取'],
            ['QLOAD', '分时热负荷', '负荷', '负荷曲线', '热提取'],
            ['ELEC_BUS', '电总线', '总线', '连接设备', '平衡 + 松弛'],
            ['THERMAL_BUS', '热总线', '总线', '连接设备', '平衡 + 松弛'],
            ['H2_BUS', '氢总线', '总线', '连接设备', '平衡 + 松弛']
          ],
          caption: '组件库共 19 类（16 物理设备 + 3 总线）'
        }
      ]
    }
  ]
}
