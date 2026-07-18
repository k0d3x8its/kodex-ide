return {
  "folke/todo-comments.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },

  lazy = false,

  config = function()
    local todo_comments = require("todo-comments")

    todo_comments.setup {
      -- full override: no default keyword fallback, so FIX (default) truly
      -- disappears and there is no BUG/OPTIMIZE alias collision to reload-race
      merge_keywords = false,
      keywords = {
        TODO = { icon = " ", color = "info" },
        BUG = { icon = " ", color = "error", alt = { "FIXME" } },
        -- quick fix now, needs hardening/refactor later -- pair with a [CHORE] or
        -- [VERIFY] TODOS.md entry so the follow-up isn't forgotten
        HOTFIX = { icon = " ", color = "warning" },
        HACK = { icon = " ", color = "warning" },
        NOTE = { icon = " ", color = "hint" },
        WARN = { icon = " ", color = "warning" },
        OPTIMIZE = { icon = " ", color = "warning", alt = { "PERF", "PERFORMANCE" } },
        SECURITY = { icon = " ", color = "error" },
        TEST = { icon = "⏲ ", color = "test", alt = { "TESTING", "PASSED", "FAILED" } },
      },
    }
  end,
}
