const { contextBridge, ipcRenderer } = require('electron')
contextBridge.exposeInMainWorld('psfaShell', {
  brand: () => ipcRenderer.invoke('desktop:brand'),
  submitLicense: key => ipcRenderer.invoke('license:submit', key),
  cancelLicense: () => ipcRenderer.send('license:cancel')
})
