import assert from "node:assert/strict"
import { generateKeyPairSync } from "node:crypto"
import { spawnSync } from "node:child_process"
import { mkdtemp, writeFile, readFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { resolve, dirname } from "node:path"
import { fileURLToPath } from "node:url"
import test from "node:test"

const project = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const signer = resolve(project, ".build/artifacts/sparkle/Sparkle/bin/sign_update")

test("Sparkle verifies signed archives and rejects tampering and another key", async t => {
  const folder = await mkdtemp(resolve(tmpdir(), "reckon-update-check-"))
  t.after(() => rm(folder, { recursive: true, force: true }))
  const seed = () => generateKeyPairSync("ed25519").privateKey.export({ format: "der", type: "pkcs8" }).subarray(-32).toString("base64")
  const key = seed()
  const archive = resolve(folder, "fixture.zip")
  await writeFile(archive, "synthetic signed update contents")
  const sign = args => spawnSync(signer, ["--ed-key-file", "-", ...args], { input: key, encoding: "utf8" })
  const signed = sign(["-p", archive])
  assert.equal(signed.status, 0)
  const signature = signed.stdout.trim()
  assert.equal(sign(["--verify", archive, signature]).status, 0)
  assert.notEqual(spawnSync(signer, ["--ed-key-file", "-", "--verify", archive, signature], { input: seed() }).status, 0)
  await writeFile(archive, "tampered signed update contents")
  assert.notEqual(sign(["--verify", archive, signature]).status, 0)
  const feed = resolve(folder, "appcast.xml")
  await writeFile(feed, '<?xml version="1.0"?><rss version="2.0"><channel><title>Fixture</title></channel></rss>')
  assert.equal(sign([feed]).status, 0)
  assert.equal(sign(["--verify", feed]).status, 0)
  await writeFile(feed, (await readFile(feed, "utf8")).replace("Fixture", "Tampered"))
  assert.notEqual(sign(["--verify", feed]).status, 0)
})
