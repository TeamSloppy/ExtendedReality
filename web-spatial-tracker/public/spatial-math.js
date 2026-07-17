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
