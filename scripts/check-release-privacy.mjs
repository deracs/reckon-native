import { execFileSync } from "node:child_process"
import { readFile, readdir, stat } from "node:fs/promises"
import { homedir } from "node:os"
import { dirname, relative, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { parseEnv } from "node:util"

const project = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const args = process.argv.slice(2)
const staged = args.includes("--staged")
const files = execFileSync("git", ["ls-files", "-z"], { cwd: project, encoding: "utf8" }).split("\0").filter(Boolean)
const issues = []
let knownSecrets = []
const envIndex = args.indexOf("--env-file")
if (envIndex >= 0) {
  if (!args[envIndex + 1]) throw new Error("Privacy check requires an env file path.")
  const values = parseEnv(await readFile(resolve(args[envIndex + 1]), "utf8"))
  knownSecrets = Object.entries(values).filter(([key, value]) => /TOKEN|SECRET|PASSWORD|API_KEY|DATABASE_URL/.test(key) && value.length >= 12).map(([, value]) => Buffer.from(value))
}
const personalHome = Buffer.from(homedir())
const personalSourcePath = personalHome.length > 6 && homedir() !== "/Users/runner" && homedir() !== "/home/runner"
const patterns = [
  ["Akahu credential", /\b(?:app_token|user_token)_[A-Za-z0-9]{24,}\b/g],
  ["GitHub credential", /\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b/g],
  ["NZ bank account number", /\b[0-9]{2}-[0-9]{4}-[0-9]{7}-[0-9]{2,3}\b/g],
  ["private key", /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/g],
  ["live Akahu account or transaction ID", /\b(?:acc|trans)_[a-zA-Z0-9]{16,}\b/g],
]
function inspect(label, bytes) {
  if (knownSecrets.some(secret => bytes.includes(secret))) issues.push(`${label}: matches a saved secret`)
  if (personalSourcePath && bytes.includes(personalHome)) issues.push(`${label}: personal home path`)
  const text = bytes.toString("utf8")
  for (const [name, pattern] of patterns) {
    pattern.lastIndex = 0
    if (pattern.test(text)) issues.push(`${label}: ${name}`)
  }
}
for (const file of files) {
  if (/(?:^|\/)(?:\.env(?:\..*)?|node_modules|\.build|dist|\.swiftpm|\.DS_Store)(?:\/|$)|\.(?:enc|sqlite|sqlite3|db|p12|pfx|pem|key|mobileprovision|zip|dmg|log)$|\.app\//i.test(file)) {
    issues.push(`${file}: private or generated file must not be tracked`)
  }
  inspect(file, staged ? execFileSync("git", ["show", `:${file}`], { cwd: project, maxBuffer: 32 * 1024 * 1024 }) : await readFile(resolve(project, file)))
}
const appIndex = args.indexOf("--app")
if (appIndex >= 0) {
  if (!args[appIndex + 1]) throw new Error("Privacy check requires an app bundle path.")
  const app = resolve(args[appIndex + 1])
  async function inspectBundle(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const path = resolve(directory, entry.name)
      if (entry.isDirectory()) await inspectBundle(path)
      else if (entry.isSymbolicLink()) issues.push(`app/${relative(app, path)}: unexpected symbolic link`)
      else if ((await stat(path)).size > 0) inspect(`app/${relative(app, path)}`, await readFile(path))
      if (/^\.env(?:\.|$)|\.(?:enc|sqlite|sqlite3|db|p12|pfx|pem|key|mobileprovision|log)$/.test(entry.name)) issues.push(`app/${relative(app, path)}: private file`)
    }
  }
  await inspectBundle(app)
}
if (issues.length) {
  console.error(`Release privacy check failed:\n${issues.join("\n")}`)
  process.exitCode = 1
} else {
  console.log(`Release privacy check passed: ${files.length} tracked files${appIndex >= 0 ? " and app bundle" : ""}${envIndex >= 0 ? ", including comparison with saved secrets" : ""}. Values were not printed.`)
}
