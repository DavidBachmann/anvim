---@module "luassert"

local bashread = require("anvim.bashread")

local dir = vim.fn.resolve(vim.fn.tempname())
local function write(name, n)
  local lines = {}
  for i = 1, n do
    lines[i] = ("line %d"):format(i)
  end
  vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. name), "p")
  vim.fn.writefile(lines, dir .. "/" .. name)
  return dir .. "/" .. name
end
local a = write("a.txt", 9)
local b = write("b.txt", 3)
local c = write("sub/c.txt", 50)
local spaced = write("with space.txt", 2)
local empty = write("empty.txt", 0)
vim.fn.mkdir(dir .. "/folder", "p")
vim.uv.fs_symlink(dir .. "/sub", dir .. "/link")

local function reads(line, cwd)
  return (bashread.parse(line, cwd == nil and dir or cwd))
end

describe("bashread.parse", function()
  it("reads whole files with cat and nl", function()
    assert.are.same({ { path = a } }, reads("cat a.txt"))
    assert.are.same({ { path = a } }, reads("cat -n a.txt"))
    assert.are.same({ { path = a }, { path = b } }, reads("cat a.txt b.txt"))
    assert.are.same({ { path = a } }, reads("nl a.txt"))
    assert.are.same({ { path = a } }, reads("nl -ba a.txt"))
    -- -s takes a value, which is no file even when one has its name.
    assert.are.same({ { path = b } }, reads("nl -s a.txt b.txt"))
    assert.are.same({ { path = a } }, reads("/bin/cat a.txt"))
    assert.are.same({ { path = empty } }, reads("cat empty.txt"))
  end)

  it("follows quoting, escapes, comments and line continuations", function()
    assert.are.same({ { path = spaced } }, reads("cat 'with space.txt'"))
    assert.are.same({ { path = spaced } }, reads('cat "with space.txt"'))
    assert.are.same({ { path = spaced } }, reads("cat with\\ space.txt"))
    assert.are.same({ { path = a } }, reads("cat a.txt # the first"))
    assert.are.same({ { path = a } }, reads("cat \\\n  a.txt"))
    assert.are.same({ { path = a } }, reads("FOO=1 BAR='x y' cat a.txt"))
    assert.are.same({}, reads("cat 'a.txt"), "an open quote")
  end)
end)

describe("bashread.grep", function()
  local function hits(line, output)
    local spec = bashread.grep(line, dir)
    return spec and bashread.hits(spec, output)
  end

  it("reads N:text for one file and path:N:text for several", function()
    assert.are.same(
      { { path = a, line = 2 }, { path = a, line = 5 } },
      hits("grep -n line a.txt", "2:line 2\n5:line 5\n")
    )
    assert.are.same({ { path = a, line = 2 } }, hits("rg -n line a.txt", "2:line 2"))
    -- ugrep, Claude Code's grep, names the file with -r also for one file.
    assert.are.same({ { path = a, line = 2 } }, hits("grep -rn line a.txt", "a.txt:2:line 2"))
    assert.are.same(
      { { path = a, line = 2 }, { path = c, line = 12 } },
      hits("grep -rn line .", "a.txt:2:line 2\nsub/c.txt:12:line 12: with: colons\n")
    )
    assert.are.same(
      { { path = a, line = 2 }, { path = c, line = 12 } },
      hits("grep -n line a.txt sub/c.txt", "./a.txt:2:x\n" .. dir .. "/sub/c.txt:12:y")
    )
    assert.are.same({ { path = c, line = 3 } }, hits("rg --vimgrep line", "sub/c.txt:3:1:line 3"))
    assert.are.same({ { path = a, line = 3 } }, hits("grep -n -e line -e x a.txt", "3:line 3"))
    -- A line of text that looks like a hit with a path is the hit's text.
    assert.are.same({ { path = a, line = 12 } }, hits("grep -n x a.txt", "12:b.txt:3:x"))
  end)
end)
