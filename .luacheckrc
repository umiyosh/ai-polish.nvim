std = "luajit"
globals = { "vim" }
max_line_length = 120
-- Prompt text and type annotations read better unwrapped.
max_string_line_length = false
max_comment_line_length = false
files["tests"] = { std = "+busted" }
