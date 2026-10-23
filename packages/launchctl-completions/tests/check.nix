{
  callPackage,
  fish,
  zsh,
  launchctl-completions,
}:
let
  makeTest = callPackage ../../../lib/testing/make-test.nix { };
  share = "${launchctl-completions}/share";
in
makeTest {
  name = "launchctl-completions";
  inputs = [
    fish
    zsh
  ];
  tests = {
    "zsh finds the completion, and it parses" = ''
      zsh -n ${share}/zsh/site-functions/_launchctl
    '';
    "fish finds the completion, and it parses" = ''
      fish --no-execute ${share}/fish/vendor_completions.d/launchctl.fish
    '';
    "fish completes the subcommands" = ''
      run fish -c 'source ${share}/fish/vendor_completions.d/launchctl.fish; complete -C "launchctl boot"'
      assert_line --regexp '^bootout	'
      assert_line --regexp '^bootstrap	'
    '';
  };
}
