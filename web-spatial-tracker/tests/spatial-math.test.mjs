import assert from "node:assert/strict";
import test from "node:test";
import { gazeDirection, projectedTransformSize, rotatePointByPose } from "../public/spatial-math.js";

test("positive Core Motion yaw points gaze left in world coordinates", () => {
  const direction = gazeDirection({ yaw: 20, pitch: 0 });
  assert.ok(direction.x < 0);
  assert.ok(direction.z < 0);
});

test("negative Core Motion yaw points gaze right in world coordinates", () => {
  const direction = gazeDirection({ yaw: -20, pitch: 0 });
  assert.ok(direction.x > 0);
  assert.ok(direction.z < 0);
});

test("WindowTransform3DoF size is interpreted as viewport fractions", () => {
  const size = projectedTransformSize({ width: 0.72, height: 0.68, virtualDistance: 1 });
  assert.equal(size.viewportWidth, 0.72);
  assert.equal(size.viewportHeight, 0.68);
  assert.equal(size.worldWidth, 1.728);
  assert.equal(size.worldHeight, 0.9180000000000001);
  assert.ok(size.worldWidth / size.worldHeight > 1.8);
});

test("virtual distance scales projected window size", () => {
  const size = projectedTransformSize({ width: 0.72, height: 0.68, virtualDistance: 1.5 });
  assert.equal(size.viewportWidth, 0.48);
  assert.ok(Math.abs(size.viewportHeight - 0.45333333333333337) < 0.000001);
});

test("positive phone yaw rotates its forward vector to the left", () => {
  const forward = rotatePointByPose({ x: 0, y: 0, z: -1 }, { yaw: 20, pitch: 0, roll: 0 });
  assert.ok(forward.x < 0);
  assert.ok(forward.z < 0);
});

test("positive phone pitch rotates its forward vector upward", () => {
  const forward = rotatePointByPose({ x: 0, y: 0, z: -1 }, { yaw: 0, pitch: 20, roll: 0 });
  assert.ok(forward.y > 0);
});
