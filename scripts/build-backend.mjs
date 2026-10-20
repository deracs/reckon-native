import { readFile, writeFile, mkdir } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { spawnSync } from "node:child_process"

const project = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const reckon = resolve(project, "Backend/Reckon")
const { build } = await import("esbuild")
const buildDirectory = resolve(project, ".build/backend")
await mkdir(buildDirectory, { recursive: true })

const paths = {
  "effect": [resolve(project, "node_modules/effect/dist/index")],
  "effect/*": [resolve(project, "node_modules/effect/dist/*")],
  "@effect/platform-node": [resolve(project, "node_modules/@effect/platform-node/dist/index")],
  "@reckon/akahu": [resolve(reckon, "packages/akahu/src/index.ts")],
  "@reckon/api": [resolve(reckon, "packages/api/src/index.ts")],
  "@reckon/domain": [resolve(reckon, "packages/domain/src/index.ts")],
  "@reckon/native-handlers": [resolve(reckon, "apps/server/src/handlers.ts")],
}
const tsconfig = resolve(buildDirectory, "tsconfig.json")
await writeFile(tsconfig, JSON.stringify({
  extends: resolve(project, "tsconfig.base.json"),
  compilerOptions: {
    // The shared Reckon sources do not compile under these two stronger flags.
    strict: true, noUncheckedIndexedAccess: false, exactOptionalPropertyTypes: false,
    noImplicitOverride: true, noFallthroughCasesInSwitch: true,
    module: "Preserve", moduleResolution: "Bundler", types: ["node"],
    typeRoots: [resolve(project, "node_modules/@types")], paths,
  },
  include: [resolve(project, "Backend/**/*.ts")],
}, null, 2))

if (process.argv.includes("--check")) {
  const checked = spawnSync(resolve(project, "node_modules/.bin/tsc"), ["--project", tsconfig], { stdio: "inherit" })
  process.exit(checked.status ?? 1)
}

const result = await build({
  absWorkingDir: project,
  entryPoints: [resolve(project, "Backend/backend-main.ts")],
  outfile: resolve(buildDirectory, "backend.cjs"),
  bundle: true, platform: "node", format: "cjs", target: "node24", tsconfig,
  minifyWhitespace: true, metafile: true, legalComments: "eof", logLevel: "info",
})
await writeFile(resolve(buildDirectory, "metafile.json"), JSON.stringify(result.metafile))
const notices = new Map()
for (const input of Object.keys(result.metafile.inputs)) {
  let directory = dirname(resolve(input))
  while (directory !== dirname(directory)) {
    try {
      const metadata = JSON.parse(await readFile(resolve(directory, "package.json"), "utf8"))
      for (const filename of ["LICENSE", "LICENSE.md", "LICENSE.txt", "license", "license.md"]) {
        try {
          const text = await readFile(resolve(directory, filename), "utf8")
          notices.set(`${metadata.name}@${metadata.version}`, text)
          break
        } catch (error) { if (error.code !== "ENOENT") throw error }
      }
      break
    } catch (error) { if (error.code !== "ENOENT") throw error }
    directory = dirname(directory)
  }
}
await writeFile(resolve(buildDirectory, "THIRD-PARTY-NOTICES.txt"), [...notices].map(([name, text]) => `${name}\n${text}`).join("\n\n"))
