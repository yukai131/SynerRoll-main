const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('synerroll', {
  platform: process.platform,
  versions: {
    electron: process.versions.electron,
    chrome: process.versions.chrome,
    node: process.versions.node
  }
})
