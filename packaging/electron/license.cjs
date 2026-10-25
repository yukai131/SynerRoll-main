const { createHash } = require('node:crypto')
const keys = require('./license-keys.json')

function verifyLicenseKey(inputKey) {
  if (typeof inputKey !== 'string') return { valid: false, isSpecial: false }
  const inputHash = createHash('md5').update(inputKey).digest('hex')
  const isSpecial = keys.special.includes(inputHash)
  return { valid: isSpecial || keys.normal.includes(inputHash), isSpecial }
}
module.exports = { verifyLicenseKey }
