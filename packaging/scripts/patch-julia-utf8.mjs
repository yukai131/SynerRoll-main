import { readFileSync, writeFileSync, copyFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { rcedit } from 'rcedit'

const executable = resolve(process.argv[2])
const binary = readFileSync(executable)
// 官方 Julia 的 RT_MANIFEST 为 UTF-8 XML；保留全部现有权限、兼容和长路径声明。
const text = binary.toString('utf8')
const start = text.indexOf('<assembly ')
const end = text.indexOf('</assembly>', start)
if (start < 0 || end < start) throw Error('Julia application manifest not found; refusing to replace it')
const original = text.slice(start, end + '</assembly>'.length)
if (!original.includes('<activeCodePage')) {
  const closing = '</asmv3:windowsSettings>'
  if (!original.includes(closing)) throw Error('Unsupported Julia manifest structure')
  copyFileSync(executable, join(dirname(executable), 'julia-original.exe'))
  const manifest = original.replace(closing,
    '<activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">UTF-8</activeCodePage>\n    ' + closing)
  const manifestPath = join(dirname(executable), 'psfa-utf8.manifest')
  writeFileSync(manifestPath, manifest)
  await rcedit(executable, { 'application-manifest': manifestPath })
}
console.log('Julia process manifest requests UTF-8 (Windows 10 1903+); original executable preserved.')
