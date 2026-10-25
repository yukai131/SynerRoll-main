const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('synerroll', {
  platform: process.platform,
  openLocation: location => ipcRenderer.invoke('desktop:open-location', location),
  versions: {
    electron: process.versions.electron,
    chrome: process.versions.chrome,
    node: process.versions.node
  }
})
