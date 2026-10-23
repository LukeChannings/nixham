# The image builds only on aarch64-linux.
{
  makeTest,
  linux-builder-image,
  jq,
}:
makeTest {
  name = "linux-builder-image";
  inputs = [ jq ];
  meta.platforms = [ "aarch64-linux" ];
  tests."the archive's embedded ref equals passthru.imageRef" = ''
    run jq -r '.manifests[].annotations["org.opencontainers.image.ref.name"]' \
      < <(tar -xOf ${linux-builder-image} index.json)
    assert_output ${linux-builder-image.imageRef}
  '';
}
