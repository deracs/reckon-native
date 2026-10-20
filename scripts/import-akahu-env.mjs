import { spawn } from "node:child_process"
import { readFile } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { parseEnv } from "node:util"

const project = resolve(dirname(fileURLToPath(import.meta.url)), "..")
try {
  const filename = process.argv[2]
  if (!filename) throw new Error("Missing .env path")
  const values = parseEnv(await readFile(resolve(filename), "utf8"))
  if (!values.AKAHU_APP_TOKEN?.trim() || !values.AKAHU_USER_TOKEN?.trim()) throw new Error("Missing Akahu tokens")
  const appBundle = process.argv[3] ? resolve(process.argv[3]) : resolve(project, "dist/Reckon.app")
  const executable = resolve(appBundle, "Contents/MacOS/Reckon")
  const status = await new Promise((resolveStatus, reject) => {
    const child = spawn(executable, ["--import-akahu-credentials"], { stdio: ["pipe", "pipe", "pipe"] })
    child.on("error", reject)
    child.stdin.on("error", reject)
    child.stdout.resume()
    child.stderr.resume()
    child.on("close", code => resolveStatus(code))
    child.stdin.end(JSON.stringify({ appToken: values.AKAHU_APP_TOKEN, userToken: values.AKAHU_USER_TOKEN }))
  })
  if (status !== 0) throw new Error("Keychain import did not succeed")
  console.log("Akahu tokens imported into Reckon’s Keychain entry.")
} catch {
  console.error("Could not import Akahu tokens. Check the .env path, token fields, and Keychain access.")
  process.exitCode = 1
}
