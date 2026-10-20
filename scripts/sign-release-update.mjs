import { createPrivateKey, createPublicKey } from "node:crypto"
import { execFileSync, spawnSync } from "node:child_process"
import { writeFile, stat } from "node:fs/promises"
import { resolve, dirname, basename } from "node:path"
import { fileURLToPath } from "node:url"

const project = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const archive = resolve(process.argv[2])
const plist = resolve(project, "dist/Reckon.app/Contents/Info.plist")
const field = (name) =>
  execFileSync("/usr/libexec/PlistBuddy", ["-c", `Print ${name}`, plist], { encoding: "utf8" }).trim()
const expectedKey = field("SUPublicEDKey")
const privateKey = process.env.SPARKLE_PRIVATE_KEY?.trim()
const tools = resolve(project, ".build/artifacts/sparkle/Sparkle/bin")
let signingArgs
if (privateKey) {
  const seed = Buffer.from(privateKey, "base64")
  if (seed.length !== 32) throw new Error("Update signing key must be a Sparkle Ed25519 seed.")
  const key = createPrivateKey({
    key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]),
    format: "der",
    type: "pkcs8",
  })
  const actualKey = createPublicKey(key).export({ format: "der", type: "spki" }).subarray(-32).toString("base64")
  if (actualKey !== expectedKey) throw new Error("Update signing key does not match the app's public key.")
  signingArgs = ["--ed-key-file", "-"]
} else if (process.env.CI) {
  throw new Error("Release signing requires the SPARKLE_PRIVATE_KEY Actions secret.")
} else {
  const key = execFileSync(resolve(tools, "generate_keys"), ["--account", "nz.reckon.native.update-signing", "-p"], {
    encoding: "utf8",
  }).trim()
  if (key !== expectedKey) throw new Error("Local update signing key does not match the app's public key.")
  signingArgs = ["--account", "nz.reckon.native.update-signing"]
}
function signUpdate(args) {
  const result = spawnSync(resolve(tools, "sign_update"), [...signingArgs, ...args], {
    input: privateKey,
    encoding: "utf8",
  })
  if (result.status !== 0) throw new Error("Sparkle update signing or verification failed.")
  return result.stdout.trim()
}
const signature = signUpdate(["-p", archive])
if (Buffer.from(signature, "base64").length !== 64) throw new Error("Invalid Sparkle archive signature.")
signUpdate(["--verify", archive, signature])
await writeFile(
  `${archive}.update.json`,
  JSON.stringify(
    {
      archive: basename(archive),
      version: field("CFBundleShortVersionString"),
      build: field("CFBundleVersion"),
      minimumSystemVersion: field("LSMinimumSystemVersion"),
      architecture: process.arch === "arm64" ? "arm64" : "x86_64",
      length: (await stat(archive)).size,
      signature,
      publicKey: expectedKey,
    },
    null,
    2,
  ) + "\n",
)
console.log(`Signed and verified update archive: ${basename(archive)}`)
