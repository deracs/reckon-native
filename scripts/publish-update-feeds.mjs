import { execFileSync, spawnSync } from "node:child_process"
import { readFile, writeFile, mkdir } from "node:fs/promises"
import { resolve, dirname } from "node:path"
import { fileURLToPath } from "node:url"

const project = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const repository = "deracs/reckon-native"
const tag = process.argv[2]
const publish = process.argv.includes("--publish")
if (!/^v\d+\.\d+\.\d+$/.test(tag ?? "")) throw new Error("Update publication requires a stable version tag.")
const privateKey = process.env.SPARKLE_PRIVATE_KEY?.trim()
const signer = resolve(project, ".build/artifacts/sparkle/Sparkle/bin/sign_update")
const output = resolve(project, ".build/update-feeds")
await mkdir(output, { recursive: true })
const xml = value => String(value).replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
function github(path, method = "GET", body) {
  return JSON.parse(execFileSync("gh", ["api", `repos/${repository}/${path}`, "--method", method, ...(body ? ["--input", "-"] : [])], {
    input: body ? JSON.stringify(body) : undefined, encoding: "utf8", maxBuffer: 8 * 1024 * 1024,
  }))
}
const release = publish ? github(`releases/tags/${tag}`) : null
const expectedKey = execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print SUPublicEDKey", resolve(project, "Resources/Info.plist")], { encoding: "utf8" }).trim()
const entries = []
for (const architecture of ["arm64", "x86_64"]) {
  const name = `Reckon-${tag.slice(1)}-macOS-${architecture}.zip`
  const metadata = JSON.parse(await readFile(resolve(project, "release", `${name}.update.json`), "utf8"))
  if (metadata.version !== tag.slice(1) || metadata.architecture !== architecture || metadata.archive !== name
    || metadata.publicKey !== expectedKey || !/^[1-9]\d*$/.test(metadata.build)
    || Buffer.from(metadata.signature, "base64").length !== 64 || !Number.isSafeInteger(metadata.length) || metadata.length <= 0) {
    throw new Error("Update feed metadata does not match this release.")
  }
  const archiveCheck = spawnSync(signer, [
    ...(privateKey ? ["--ed-key-file", "-"] : ["--account", "nz.reckon.native.update-signing"]),
    "--verify", resolve(project, "release", name), metadata.signature,
  ], { input: privateKey, encoding: "utf8" })
  if (archiveCheck.status !== 0) throw new Error("Update archive failed signature verification before publication.")
  const asset = release?.assets.find(item => item.name === name)
  if (publish && (!asset || asset.size !== metadata.length)) throw new Error("Update archive was not uploaded intact.")
  const assetID = asset?.id ?? (architecture === "arm64" ? 1001 : 1002)
  const text = `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<title>Reckon updates</title><link>https://github.com/${repository}/releases</link><description>Signed Reckon updates for macOS.</description><language>en-NZ</language>
<item><title>Reckon ${xml(metadata.version)}</title>
<sparkle:version>${xml(metadata.build)}</sparkle:version><sparkle:shortVersionString>${xml(metadata.version)}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>${xml(metadata.minimumSystemVersion)}</sparkle:minimumSystemVersion>
<enclosure url="https://api.github.com/repos/${repository}/releases/assets/${assetID}" length="${metadata.length}" type="application/octet-stream" sparkle:edSignature="${xml(metadata.signature)}" />
</item></channel></rss>\n`
  const filename = resolve(output, `appcast-${architecture}.xml`)
  await writeFile(filename, text)
  const keyArgs = privateKey ? ["--ed-key-file", "-"] : ["--account", "nz.reckon.native.update-signing"]
  for (const args of [[...keyArgs, filename], [...keyArgs, "--verify", filename]]) {
    const result = spawnSync(signer, args, { input: privateKey, encoding: "utf8" })
    if (result.status !== 0) throw new Error("Update feed signing or verification failed.")
  }
  entries.push({ path: `updates/appcast-${architecture}.xml`, mode: "100644", type: "blob", content: await readFile(filename, "utf8") })
}
if (publish) {
  if (!privateKey) throw new Error("Publishing update feeds requires the Actions signing secret.")
  github(`releases/${release.id}`, "PATCH", { draft: false })
  const ref = github("git/ref/heads/main")
  const parent = github(`git/commits/${ref.object.sha}`)
  const tree = github("git/trees", "POST", { base_tree: parent.tree.sha, tree: entries })
  const identity = { name: "github-actions[bot]", email: "41898282+github-actions[bot]@users.noreply.github.com" }
  const commit = github("git/commits", "POST", { message: `Publish signed update feeds for ${tag}`, tree: tree.sha, parents: [ref.object.sha], author: identity, committer: identity })
  github("git/refs/heads/main", "PATCH", { sha: commit.sha, force: false })
}
console.log(`Signed and verified both update feeds${publish ? " and published the release" : " (local preview only)"}.`)
