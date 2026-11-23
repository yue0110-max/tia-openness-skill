/**
 * Smoke test for dsh-tia-openness.
 *
 * It does not need DSH: it fakes the two injection points the host half uses
 * (`skills.register`, `tools.register`) and asserts that
 *
 *   * the bundled skill is registered with a resource base pointing at the
 *     payload directory, so relative paths in SKILL.md stay resolvable;
 *   * the status tool is registered and returns a diagnosis that satisfies its
 *     own output schema;
 *   * `apply()` survives a host without either service — the boot-path contract
 *     is that it never throws.
 *
 * Run with: node --test test/smoke.mjs
 */
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import plugin, { apply } from "../index.js";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

/** Minimal host stand-in: records what the plugin registers. */
function fakeContext() {
  const registered = { skills: [], tools: [] };
  const ctx = {
    services: { skills: {}, tools: {} },
    inject(deps, callback) {
      for (const dependency of deps) {
        assert.ok(dependency in ctx.services, `plugin injected an unknown service: ${dependency}`);
      }
      callback(ctx.services);
    },
    get(name) {
      return ctx.services[name];
    },
  };
  ctx.services.skills.register = (skill) => {
    registered.skills.push(skill);
    return () => {};
  };
  ctx.services.tools.register = (tool) => {
    registered.tools.push(tool);
    return () => {};
  };
  return { ctx, registered };
}

test("registers the tia-openness skill with a resolvable resource base", () => {
  const { ctx, registered } = fakeContext();
  apply(ctx);

  assert.equal(registered.skills.length, 1, "expected exactly one skill registration");
  const skill = registered.skills[0];

  assert.equal(skill.name, "tia-openness");
  assert.equal(skill.source, "custom");
  assert.deepEqual(skill.invocation, { modelInvocable: true, userInvocable: true });
  assert.ok(typeof skill.content === "string" && skill.content.length > 500, "skill content looks empty");
  assert.ok(typeof skill.description === "string" && skill.description.length > 20, "skill description looks empty");

  assert.equal(skill.resourceBase.kind, "directory");
  assert.equal(resolve(skill.resourceBase.path), join(packageRoot, "tia-openness"));
  assert.ok(existsSync(join(skill.resourceBase.path, "SKILL.md")), "resource base must contain SKILL.md");
  for (const script of ["setup.ps1", "run.ps1", "stage-project.ps1", "whitelist.ps1"]) {
    assert.ok(existsSync(join(skill.resourceBase.path, "scripts", script)), `missing scripts\\${script}`);
  }
});

test("registers the status tool and returns a schema-shaped diagnosis", () => {
  const { ctx, registered } = fakeContext();
  apply(ctx);

  assert.equal(registered.tools.length, 1, "expected exactly one tool registration");
  const tool = registered.tools[0];

  assert.equal(tool.name, "tia_openness_status");
  assert.equal(tool.parameters.type, "object");
  assert.deepEqual(tool.parameters.properties, {});
  assert.equal(tool.parameters.additionalProperties, false);
  assert.ok(tool.output && tool.output.schema, "tool must declare an output schema");

  const value = tool.execute({}, {});
  for (const key of tool.output.schema.required) {
    assert.ok(key in value, `tool output is missing required field ${key}`);
  }
  assert.ok(typeof value.summary === "string" && value.summary.length > 40, "summary looks empty");
  assert.ok(value.summary.includes("TIA Portal"), "summary must report the TIA Portal probe");
  assert.ok(typeof value.nextStep === "string" && value.nextStep.length > 10);
  assert.equal(typeof value.tiaPortalInstalled, "boolean");

  const rendered = tool.output.render({}, value);
  assert.equal(rendered.length, 1);
  assert.equal(rendered[0].type, "text");
  assert.equal(rendered[0].text, value.summary);
});

test("apply never throws, even on a host without skills or tools", () => {
  assert.doesNotThrow(() => apply({}));
  assert.doesNotThrow(() => apply(undefined));
  assert.doesNotThrow(() =>
    apply({
      inject() {
        throw new Error("no such service");
      },
    }),
  );
});

test("package manifest declares the bundle patch that the marketplace checks", () => {
  const manifest = JSON.parse(readFileSync(join(packageRoot, "package.json"), "utf8"));
  assert.equal(manifest.name, "dsh-tia-openness");
  assert.ok(manifest.dsh && manifest.dsh.bundle, "package.json must declare dsh.bundle");
  assert.ok(existsSync(join(packageRoot, manifest.dsh.bundle.patch)), "bundle patch file is missing");

  const patch = readFileSync(join(packageRoot, manifest.dsh.bundle.patch), "utf8");
  assert.ok(/^\s*-\s*id:\s*dsh-tia-openness\s*$/m.test(patch), "patch must insert a row whose id is the package name");
  assert.equal(plugin.name, "dsh-tia-openness");
  assert.equal(typeof plugin.apply, "function");
});
