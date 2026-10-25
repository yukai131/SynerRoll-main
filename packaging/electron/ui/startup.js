window.psfaShell.brand().then(brand => {
  document.getElementById('appTitle').textContent = brand.displayName
  document.getElementById('publisher').textContent = brand.publisher
  document.getElementById('version').textContent = `版本 ${brand.version}`
}).catch(() => {})
