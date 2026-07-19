const toRadians = (degrees) => Number(degrees || 0) * Math.PI / 180;

/** Core Motion positive yaw means left; world X is positive to the right. */
export function gazeDirection(pose = {}) {
  const yaw = toRadians(pose.yaw);
  const pitch = toRadians(pose.pitch);
  return {
    x: -Math.sin(yaw) * Math.cos(pitch),
    y: Math.sin(pitch),
    z: -Math.cos(yaw) * Math.cos(pitch),
  };
}

/** Rotate a local device-space point into the debug world's XYZ axes. */
export function rotatePointByPose(point, pose = {}) {
  const roll = toRadians(pose.roll);
  const pitch = toRadians(pose.pitch);
  const yaw = toRadians(pose.yaw);

  const rolled = {
    x: point.x * Math.cos(roll) - point.y * Math.sin(roll),
    y: point.x * Math.sin(roll) + point.y * Math.cos(roll),
    z: point.z,
  };
  const pitched = {
    x: rolled.x,
    y: rolled.y * Math.cos(pitch) - rolled.z * Math.sin(pitch),
    z: rolled.y * Math.sin(pitch) + rolled.z * Math.cos(pitch),
  };
  return {
    x: pitched.x * Math.cos(yaw) + pitched.z * Math.sin(yaw),
    y: pitched.y,
    z: -pitched.x * Math.sin(yaw) + pitched.z * Math.cos(yaw),
  };
}

/**
 * Mirrors WindowProjection's viewport-fraction sizing on a 16:9 reference
 * plane used by the third-person debug scene.
 */
export function projectedTransformSize(transform = {}) {
  const distance = Number(transform.virtualDistance) || 1;
  const viewportWidth = (Number(transform.width) || 0.56) / distance;
  const viewportHeight = (Number(transform.height) || 0.58) / distance;
  return {
    viewportWidth,
    viewportHeight,
    worldWidth: viewportWidth * 2.4,
    worldHeight: viewportHeight * 1.35,
  };
}
