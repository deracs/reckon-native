import { readFile, writeFile, mkdir, readdir } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { execFileSync } from "node:child_process"

const project = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const manifest = resolve(project, "Backend/Cargo.toml")
const env = {
  ...process.env,
  CARGO_TARGET_DIR: resolve(project, ".build/rust"),
  // Avoid embedding local source and Cargo registry paths in distributable binaries.
  RUSTFLAGS: `${process.env.RUSTFLAGS ?? ""} --remap-path-prefix=${project}=/reckon-native --remap-path-prefix=${process.env.HOME}/.cargo=/cargo`,
}
execFileSync("cargo", ["build", "--manifest-path", manifest, "--release", "--locked"], { env, stdio: "inherit" })
const host = execFileSync("rustc", ["-vV"], { encoding: "utf8" }).match(/^host: (.+)$/m)[1]
const metadata = JSON.parse(
  execFileSync(
    "cargo",
    ["metadata", "--manifest-path", manifest, "--locked", "--format-version", "1", "--filter-platform", host],
    {
      env,
      encoding: "utf8",
      maxBuffer: 16 * 1024 * 1024,
    },
  ),
)
const compiled = new Set(metadata.resolve.nodes.map((node) => node.id))
const notices = []
for (const dependency of metadata.packages.filter((dependency) => compiled.has(dependency.id) && dependency.source)) {
  const directory = dirname(dependency.manifest_path)
  const licenses = (await readdir(directory)).filter((name) => /^(?:licen[sc]e|copying|notice)(?:[.-]|$)/i.test(name))
  if (dependency.license_file && !licenses.includes(dependency.license_file)) licenses.push(dependency.license_file)
  const texts = []
  for (const license of licenses) {
    try {
      texts.push(await readFile(resolve(directory, license), "utf8"))
    } catch (error) {
      if (error.code !== "EISDIR") throw error
    }
  }
  if (!texts.length) throw new Error(`Backend dependency license text missing for ${dependency.name}.`)
  notices.push(`${dependency.name}@${dependency.version} (${dependency.license ?? "see license"})\n${texts.join("\n")}`)
}
const buildDirectory = resolve(project, ".build/backend")
await mkdir(buildDirectory, { recursive: true })
await writeFile(resolve(buildDirectory, "THIRD-PARTY-NOTICES.txt"), notices.join("\n\n"))
