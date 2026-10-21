## About

- A repo containing Nix packages and modules
- Should never contain any code that depends on private repositories, or secrets in any form.
- Agents can't edit this file. Only people. (You can make suggestions though.)

## Usage

- Use `just` to run commands. Discover runnable commands by invoking `just` with no arguments
- Environment is managed with a Nix devshell and direnv. If any tools are missing, STOP what you're doing and tell the user.
- CI is both Forgejo and GitHub. Forgejo is the source of truth.

## Writing good code

- Comments
  - Avoid them.
  - If you must, the comment should be for one of these purposes:
    - It explains something non-obvious and CRITICALLY important about *why* something is being done, not *what the code is doing*
    - It links to some upstream code or documentation that is relevant for the long-term maintenance of the code.
  - Keep them short and to-the-point.
- Test
  - Write a test first. Make it pass. You can change the test as you learn more.
  - Prefer unit tests, because they run faster, but use integration tests to simulate varied scenarios.
- Always run the linting and formatting tools. Fix errors that can't be auto-fixed.
- Reduce, reduce, reduce. Refactor, refactor, refactor. Relentlessly reduce the code to the bare minimum needed to achieve the functionality, whilst still remaining readable.

## Change management

- Scenario: You write some code and commit it. Later, you discover that something was missing or broken. You amend the original commit, you don't pile new commits on top. Reorder commits to make things easier. If the commit has already been merged into `main`, disregard this advice.
- All commits must be signed.

## Environment

- The user uses `fish`, which is NOT POSIX COMPLIANT.
- For background tasks, or user interaction, use `zmx` - it's a single-session multiplexer. e.g. `zmx attach test bash -l` will create and attach to a new bash session. (see `zmx help`)
- Running Nix's flake commands (`nix build`, `nix run`, `nix check`, etc.) is more expensive than the non-flake commands (`nix-build`, `nix-instantiate`, etc.) because they copy the repo to the store each time. Avoid them.
