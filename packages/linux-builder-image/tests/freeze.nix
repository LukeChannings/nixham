# Evaluates images, never builds them: it runs wherever Nix does.
{
  lib,
  makeTest,
  linux-builder-image,
  variant,
}:
let
  esc = s: lib.escapeShellArg (builtins.unsafeDiscardStringContext s);
  with' = module: variant [ module ];
  tag = image: esc image.imageTag;
  nixConfig = image: esc image.nixosConfig.system.build.shuttledNixConf;
  nixConf = image: esc image.nixosConfig.environment.etc."nix/nix.conf".source.text;

  cache = "https://cache.example.org";
  settings = with' { nix.settings.substituters = [ cache ]; };
in
makeTest {
  name = "linux-builder-image-freeze";
  tests = {
    "Nix settings leave the image as it is" = ''
      assert_equal ${tag settings} ${tag linux-builder-image}
      assert_equal ${tag (with' { })} ${tag linux-builder-image}
    '';
    "anything else changes the image" = ''
      assert_not_equal ${
        tag (with' {
          environment.etc.probe.text = "probe";
        })
      } ${tag linux-builder-image}
    '';
    "store paths in Nix settings are in the image" = ''
      assert_not_equal ${
        tag (with' ({ pkgs, ... }: { nix.settings.post-build-hook = "${pkgs.hello}/bin/hello"; }))
      } ${tag linux-builder-image}
    '';
    "the shuttled nix.conf carries every setting, without the image's includes" = ''
      run echo ${nixConfig settings}
      assert_line --partial ${esc "substituters = ${cache} "}
      assert_line 'sandbox = true'
      refute_output --partial '!include'
    '';
    "the image's nix.conf ends including /config's, then the environment's" = ''
      run echo ${nixConf settings}
      refute_output --partial ${esc cache}
      run tail -2 <<<"$output"
      assert_output "$(printf '%s\n' '!include /run/linux-builder/config/nix.conf' '!include /run/linux-builder/environment.conf')"
    '';
  };
}
