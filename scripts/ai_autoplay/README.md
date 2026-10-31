18xx AI Autoplay Harness

Goal

Build a command-line harness that plays an 18xx game with AI controlling every player.

The harness should:

start a fresh game by title, or continue from a saved game;
use 3 or 4 AI players where the game permits;
make exactly one top-level AI move at a time;
completely process that move before selecting the next one;
save a checkpoint after every successful move;
stop and report clearly when the AI gets stuck;
allow us to fix the AI and resume from the last good checkpoint;
ultimately play a complete game from start to finish.
The first target game is 1889 with three AI players.

Location

Source files:

scripts/ai_autoplay/