-- image.nvim — kitty-graphics image PLACEMENT, used ONLY by the Clawd pet overlay
-- (lua/utils/claude/pet_render.lua). Declared lazy with no config of its own on
-- purpose: the pet renderer owns image.setup() (integrations = {}, processor =
-- magick_cli → shells out to `convert`, no magick luarock needed) so the overlay
-- is the single place image.nvim is configured, and a machine without the Clawd
-- assets or a kitty-graphics terminal never pays for loading it. pet_render.setup
-- triggers the load on first render via require("lazy").load.
return {
  "3rd/image.nvim",
  lazy = true,
}
