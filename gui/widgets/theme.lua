-- Shared GUI theme: ONE source for the color palette and common widths.
-- Replaces the ImVec4 color literals and NUMERIC_INPUT_WIDTH that were copy-pasted across the
-- component/widget files (which had started to drift). Files alias what they need, e.g.:
--   local theme = require('gui.widgets.theme')
--   local YELLOW, RED = theme.YELLOW, theme.RED
-- Values are intentionally identical to the originals so adoption is purely a centralization.

require('ImGui') -- ensure ImVec4 is registered before we build the palette

local theme = {
    YELLOW = ImVec4(1, 1, 0, 1),
    RED = ImVec4(1, 0, 0, 1),
    GREEN = ImVec4(0, 0.8, 0, 1),
    BLACK = ImVec4(0, 0, 0, 1),
    WHITE = ImVec4(1, 1, 1, 1),
    LIGHT_GREY = ImVec4(0.75, 0.75, 0.75, 1),
    TABLE_BORDER_BLUE = ImVec4(51 / 255, 105 / 255, 173 / 255, 1.0),
    -- Semantic aliases (use these in new code):
    ACCENT = ImVec4(1, 1, 0, 1),        -- section headers (== YELLOW)
    DANGER = ImVec4(1, 0, 0, 1),        -- destructive (== RED)
    OK = ImVec4(0, 0.8, 0, 1),          -- enabled/on (== GREEN)
    MUTED = ImVec4(0.75, 0.75, 0.75, 1),-- secondary text (== LIGHT_GREY)
}

theme.WIDTHS = {
    numeric = 80, -- standard numeric input (was NUMERIC_INPUT_WIDTH in 8 files)
}

return theme
