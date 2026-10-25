const brand = require('../config/brand.json')
const stage = process.env.PSFA_STAGE_DIR || 'packaging/release-stage'
const path = require('node:path')
module.exports = {
  appId: 'cn.synerroll.workbench',
  productName: brand.displayName,
  extraMetadata: { productName: brand.displayName, version: brand.version, author: { name: brand.publisher || brand.productName }, description: brand.description },
  directories: { app: 'packaging/electron', output: 'dist/psfa', buildResources: 'packaging/resources' },
  files: ['main.js', 'runtime.cjs', 'preload.js', 'shell-preload.js', 'license.cjs', 'license-keys.json', 'ui/**', 'package.json', '!node_modules/**'],
  extraResources: [
    { from: `${stage}/app`, to: 'app' },
    { from: `${stage}/runtime`, to: 'runtime' },
    { from: 'packaging/config', to: 'config' },
    { from: 'config/brand.json', to: 'config/brand.json' },
    { from: 'packaging/electron/runtime.cjs', to: 'config/runtime.cjs' },
    { from: 'packaging/resources/icon.ico', to: 'icon.ico' },
    { from: 'packaging/README.md', to: '使用说明.md' },
    { from: `${stage}/THIRD-PARTY-NOTICES.txt`, to: 'THIRD-PARTY-NOTICES.txt' }
  ],
  asar: true,
  compression: 'normal',
  npmRebuild: false,
  afterPack: async context => {
    if (context.electronPlatformName !== 'win32') return
    const { rcedit } = require('rcedit')
    await rcedit(path.join(context.appOutDir, `${brand.productName}.exe`), {
      icon: path.resolve(__dirname, 'resources/icon.ico'),
      'file-version': brand.version,
      'product-version': brand.version,
      'version-string': {
        CompanyName: brand.publisher,
        ProductName: brand.displayName,
        FileDescription: brand.displayName,
        InternalName: brand.productName,
        OriginalFilename: `${brand.productName}.exe`,
        LegalCopyright: `Copyright © ${new Date().getFullYear()} ${brand.publisher}`
      }
    })
  },
  electronLanguages: ['en-US', 'zh-CN', 'zh-TW'],
  win: { target: [{ target: 'nsis', arch: ['x64'] }], executableName: brand.productName, icon: 'packaging/resources/icon.ico', signExecutable: false },
  nsis: {
    include: 'packaging/installer.nsh',
    oneClick: false, perMachine: false, allowElevation: false,
    allowToChangeInstallationDirectory: true, createDesktopShortcut: true,
    createStartMenuShortcut: true, deleteAppDataOnUninstall: false,
    shortcutName: brand.displayName,
    installerIcon: 'packaging/resources/icon.ico', uninstallerIcon: 'packaging/resources/icon.ico', installerHeaderIcon: 'packaging/resources/icon.ico',
    runAfterFinish: false, installerLanguages: ['zh_CN', 'en_US'],
    artifactName: 'PSFA-Setup-${version}-${arch}.${ext}'
  }
}
