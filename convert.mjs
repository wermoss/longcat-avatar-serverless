import { chromium } from 'playwright'
import fs from 'node:fs'

const URL = 'https://c33z2eildv8fa9-8188.proxy.runpod.net/'
const wf = JSON.parse(fs.readFileSync('./workflow_ui.json', 'utf8'))

const browser = await chromium.launch()
const page = await browser.newPage()
const consoleErrors = []
page.on('console', (msg) => {
  if (msg.type() === 'error') consoleErrors.push(msg.text())
})
page.on('pageerror', (err) => consoleErrors.push('pageerror: ' + err.message))

console.log('navigating...')
await page.goto(URL, { waitUntil: 'networkidle', timeout: 60000 })

console.log('waiting for window.app...')
await page.waitForFunction(() => window.app && window.app.graph, { timeout: 30000 })

console.log('inspecting app API surface...')
const surface = await page.evaluate(() => {
  return {
    hasLoadGraphData: typeof window.app.loadGraphData,
    hasGraphToPrompt: typeof window.app.graphToPrompt,
    hasLoadApiJson: typeof window.app.loadApiJson,
    appKeys: Object.keys(window.app).filter(k => typeof window.app[k] === 'function').slice(0, 60),
  }
})
console.log(JSON.stringify(surface, null, 2))

console.log('loading workflow + converting...')
const result = await page.evaluate(async (wf) => {
  await window.app.loadGraphData(wf)
  await new Promise(r => setTimeout(r, 1500))
  const p = await window.app.graphToPrompt()
  return { output: p.output, nodeCount: Object.keys(p.output || {}).length }
}, wf)

console.log('nodeCount:', result.nodeCount)
if (consoleErrors.length) {
  console.log('--- console errors (first 30) ---')
  console.log(consoleErrors.slice(0, 30).join('\n'))
}

fs.writeFileSync('./workflow_api.json', JSON.stringify(result.output, null, 2))
console.log('wrote workflow_api.json')

await browser.close()
