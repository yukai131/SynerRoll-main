const input = document.getElementById('licenseKey')
const confirm = document.getElementById('confirmButton')
const error = document.getElementById('licenseError')
window.psfaShell.brand().then(brand => {
  document.getElementById('appTitle').textContent = brand.displayName
  document.getElementById('publisher').textContent = brand.publisher
  document.getElementById('version').textContent = `版本 ${brand.version}`
}).catch(() => { error.textContent = '页面加载失败，请重新打开软件。'; confirm.disabled = true })
async function submitLicense() {
  if (confirm.disabled) return
  confirm.disabled = true
  error.textContent = ''
  try {
    const result = await window.psfaShell.submitLicense(input.value)
    if (!result.valid) {
      error.textContent = result.message
      confirm.disabled = false
      input.focus()
      input.select()
    }
  } catch {
    error.textContent = '验证失败，请重新打开软件。'
    confirm.disabled = false
  }
}
confirm.addEventListener('click', submitLicense)
document.getElementById('cancelButton').addEventListener('click', () => window.psfaShell.cancelLicense())
input.addEventListener('keydown', event => { if (event.key === 'Enter') { event.preventDefault(); submitLicense() } })
