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

local function cwd_after(line)
  return select(2, bashread.parse(line, dir))
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

  it("reads the first lines with head", function()
    local first20 = { { path = c, first = 1, last = 20 } }
    assert.are.same(first20, reads("head -n 20 sub/c.txt"))
    assert.are.same(first20, reads("head -20 sub/c.txt"))
    assert.are.same(first20, reads("head -n20 sub/c.txt"))
    assert.are.same(first20, reads("head --lines=20 sub/c.txt"))
    assert.are.same({ { path = c, first = 1, last = 10 } }, reads("head sub/c.txt"))
    assert.are.same(
      { { path = a, first = 1, last = 5 }, { path = b, first = 1, last = 5 } },
      reads("head -5 a.txt b.txt")
    )
    assert.are.same({}, reads("head -c 100 a.txt"))
    assert.are.same({}, reads("head -n 0 a.txt"))
  end)

  it("reads the last lines with tail, from the file's line count", function()
    assert.are.same({ { path = c, first = 46, last = 50 } }, reads("tail -n 5 sub/c.txt"))
    assert.are.same({ { path = c, first = 46, last = 50 } }, reads("tail -5 sub/c.txt"))
    assert.are.same({ { path = c, first = 41, last = 50 } }, reads("tail sub/c.txt"))
    assert.are.same({ { path = a, first = 1, last = 9 } }, reads("tail -n 100 a.txt"))
    assert.are.same({ { path = c, first = 40 } }, reads("tail -n +40 sub/c.txt"))
    assert.are.same({}, reads("tail -f sub/c.txt"))
    assert.are.same({}, reads("tail -c 20 sub/c.txt"))
    assert.are.same({}, reads("tail +40 sub/c.txt"))
  end)

  it("counts a file's lines again once it changed", function()
    local grow = write("grow.txt", 20)
    assert.are.same({ { path = grow, first = 16, last = 20 } }, reads("tail -n 5 grow.txt"))
    write("grow.txt", 30)
    assert.are.same({ { path = grow, first = 26, last = 30 } }, reads("tail -n 5 grow.txt"))
  end)

  it("reads the printed lines of sed -n", function()
    assert.are.same({ { path = c, first = 10, last = 20 } }, reads("sed -n 10,20p sub/c.txt"))
    assert.are.same({ { path = c, first = 10, last = 20 } }, reads("sed -n '10,20p' sub/c.txt"))
    assert.are.same({ { path = a, first = 5, last = 5 } }, reads("sed -n '5p' a.txt"))
    assert.are.same({ { path = c, first = 30 } }, reads("sed -n '30,$p' sub/c.txt"))
    assert.are.same({ { path = c, first = 30 } }, reads("sed -n 30,\\$p sub/c.txt"))
    assert.are.same({ { path = a, first = 2, last = 3 } }, reads("sed -n -e 2,3p a.txt"))
    assert.are.same({ { path = a, first = 2, last = 3 } }, reads("sed -ne 2,3p a.txt"))
    assert.are.same({}, reads("sed 's/line/LINE/' a.txt"), "no -n")
    assert.are.same({}, reads("sed -n 's/line/LINE/p' a.txt"))
    assert.are.same({}, reads("sed -i -n 1p a.txt"))
    assert.are.same({}, reads("sed -n 1,2p a.txt b.txt"), "sed numbers the lines of all files as one")
    assert.are.same({}, reads('sed -n "1,$p" a.txt'), "$p is a variable in double quotes")
    assert.are.same({}, reads("sed -n -e 1,5p -e 10p a.txt"), "two scripts")
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

  it("drops redirections, and skips a read whose output goes to a file", function()
    assert.are.same({ { path = a } }, reads("cat a.txt 2>/dev/null"))
    assert.are.same({ { path = a } }, reads("cat a.txt 2> /dev/null"))
    assert.are.same({ { path = a } }, reads("cat a.txt >&2"))
    assert.are.same({ { path = a } }, reads("cat a.txt 2>&1"))
    assert.are.same({}, reads("cat a.txt > copy.txt"))
    assert.are.same({}, reads("cat a.txt &> /dev/null"))
    assert.are.same({}, reads("cat a.txt | head -3 >> copy.txt"))
  end)

  it("reads in order across ;, &&, & and newlines, and skips what runs after ||", function()
    assert.are.same({ { path = a }, { path = b } }, reads("cat a.txt; echo ---; cat b.txt"))
    assert.are.same({ { path = a }, { path = b } }, reads("cat a.txt && cat b.txt || head sub/c.txt"))
    assert.are.same({ { path = a } }, reads("cat a.txt || cat b.txt"))
    assert.are.same({ { path = a }, { path = b } }, reads("cat a.txt || ls; cat b.txt"))
    assert.are.same({ { path = a }, { path = b } }, reads("cat a.txt & cat b.txt"))
    assert.are.same({ { path = a }, { path = b } }, reads("cat a.txt\ncat b.txt"))
    assert.are.same(
      { { path = c, first = 1, last = 200 }, { path = a } },
      reads("wc -l sub/c.txt a.txt; echo ---; sed -n 1,200p sub/c.txt; echo ---; cat a.txt")
    )
  end)

  it("reads only with the first command of a pipeline, which head, tail and sed -n narrow", function()
    assert.are.same({ { path = c, first = 1, last = 5 } }, reads("cat sub/c.txt | head -n 5"))
    assert.are.same({ { path = c, first = 1, last = 5 } }, reads("cat -n sub/c.txt | head -5"))
    assert.are.same({ { path = c, first = 40, last = 44 } }, reads("tail -n +40 sub/c.txt | head -5"))
    assert.are.same({ { path = c, first = 10, last = 12 } }, reads("sed -n 10,20p sub/c.txt | head -3"))
    assert.are.same({ { path = a, first = 1, last = 20 } }, reads("cat a.txt 2>&1 | head -20"))
    assert.are.same({ { path = c, first = 20, last = 30 } }, reads("cat -n sub/c.txt | sed -n 20,30p"))
    assert.are.same({ { path = c, first = 20, last = 30 } }, reads("nl -ba sub/c.txt | sed -n 20,30p"))
    assert.are.same({ { path = c, first = 25, last = 25 } }, reads("cat sub/c.txt | sed -n '25p'"))
    assert.are.same({ { path = c, first = 45 } }, reads("cat sub/c.txt | sed -n '45,$p'"))
    assert.are.same({ { path = c, first = 46, last = 50 } }, reads("cat sub/c.txt | tail -n 5"))
    assert.are.same({ { path = c, first = 36, last = 40 } }, reads("head -n 40 sub/c.txt | tail -n 5"))
    assert.are.same({ { path = c, first = 12, last = 13 } }, reads("tail -n +11 sub/c.txt | sed -n 2,3p"))
    assert.are.same({ { path = c, first = 14, last = 20 } }, reads("sed -n 10,20p sub/c.txt | tail -n +5"))
    assert.are.same({ { path = c, first = 21, last = 23 } }, reads("cat -n sub/c.txt | sed -n 21,30p | head -3"))
    assert.are.same({}, reads("sed -n 10,20p sub/c.txt | sed -n 15,20p"), "past the read's end")
    -- A filter sees several files as one stream.
    assert.are.same({ { path = a, first = 1, last = 3 } }, reads("cat a.txt b.txt | head -3"))
    assert.are.same({}, reads("cat a.txt b.txt | sed -n 2p"))
    for _, line in ipairs({
      "cat -n a.txt | grep line",
      "cat a.txt | wc -l",
      "nl a.txt | sort",
      "cat a.txt | sed 's/line/x/'",
      "cat a.txt | tail -c 5",
      "ls | cat a.txt",
    }) do
      assert.are.same({}, reads(line), line)
    end
  end)

  it("follows cd for later relative paths", function()
    assert.are.same({ { path = c } }, reads("cd " .. dir .. "/sub && cat c.txt"))
    assert.are.same({ { path = c } }, reads("cd sub && cat c.txt"))
    assert.are.same({ { path = a } }, reads("cd sub && cat ../a.txt"))
    assert.are.same({ { path = c } }, reads("cd " .. dir .. " && cat sub/c.txt", "/"))
    assert.are.same({}, reads("cd missing && cat a.txt"), "a failed cd")
    assert.are.same({}, reads("cd $DIR && cat a.txt"))
    assert.are.same({}, reads("pushd sub && cat c.txt"))
    assert.are.same({}, reads("cd sub | cat a.txt"), "cd in a pipeline")
    assert.are.same({}, reads("ls x || cd sub; cat c.txt"), "a cd after ||")
    assert.are.same({ { path = c } }, reads("builtin cd sub && cat c.txt"))
    assert.are.same({ { path = c } }, reads("command cd sub && cat c.txt"))
    assert.are.same({ { path = c } }, reads("cd sub & cat sub/c.txt"), "a cd in the background moves nothing")
    assert.are.same({}, reads("eval cd sub; cat c.txt"))
  end)

  it("knows the working directory after the command", function()
    assert.are.same(dir .. "/sub", cwd_after("cd sub && ls"))
    assert.are.same(dir, cwd_after("ls; cat a.txt"))
    assert.are.same(dir, cwd_after("echo $(date)"))
    assert.is_false(cwd_after("cd missing"))
    assert.is_false(cwd_after("cd $HOME/x"))
    assert.is_false(cwd_after("pushd sub"))
    assert.is_false(cwd_after("eval cd sub"))
    assert.are.same(dir .. "/sub", cwd_after("builtin cd sub"))
    assert.are.same(dir, cwd_after("cd sub &"))
    assert.are.same(dir, cwd_after("command -v cd"))
    -- The shell keeps the physical path, as pwd -P prints it.
    assert.are.same(dir .. "/sub", cwd_after("cd link && ls"))
  end)

  it("finds a cd in a line that it does not follow only where a command starts", function()
    for _, line in ipairs({
      "git commit -m \"$(cat <<'EOF'\nfix: source maps load again\n\ncd and source stay\nEOF\n)\"",
      "cat <<EOF\ncd sub\nEOF",
      'echo "cd sub" $(date)',
      "echo 'source x' $(date)",
      "(cd sub && make)",
      "echo $(cd sub; pwd)",
      "echo `cd sub` $(date)",
      "grep -rn 'cd ' . | head $(echo -3)",
      "abcd $(date) # cd sub",
    }) do
      assert.are.same(dir, cwd_after(line), line)
    end
    for _, line in ipairs({
      "cd sub; echo $(date)",
      "echo $(date) && cd sub",
      "{ cd sub; ls; }",
      "if cd sub; then ls; fi",
      "for f in a; do cd sub; done",
      "X=1 cd sub $(date)",
      "builtin cd sub $(date)",
      "source env.sh $(date)",
      ". ./env.sh $(date)",
      'eval "$(cat x)"',
      "$CMD sub",
      "echo 'open",
    }) do
      assert.is_false(cwd_after(line), line)
    end
  end)

  it("resolves relative paths only when the working directory is known", function()
    assert.are.same({}, reads("cat a.txt", false))
    assert.are.same({ { path = a } }, reads("cat " .. a, false))
  end)

  it("returns nothing for what it does not follow", function()
    for _, line in ipairs({
      "cat *.txt",
      "cat a.tx?",
      "cat [ab].txt",
      "cat {a,b}.txt",
      "cat $FILE",
      'cat "$FILE"',
      "cat ${FILE}",
      "cat $(echo a.txt)",
      "cat `echo a.txt`",
      "cat a.txt; echo $(date)",
      "cat <<EOF\nline\nEOF",
      "cat <<< a.txt",
      "cat <(echo a.txt)",
      "(cd sub && cat c.txt)",
      "{ cat a.txt; }",
      "if [ -f a.txt ]; then cat a.txt; fi",
      "for f in a.txt; do cat $f; done",
      "cat missing.txt",
      "cat folder",
      "head -n 5 folder",
      "ls a.txt",
      "wc -l a.txt",
      "grep line a.txt",
      "cat",
      "cat -",
      "cat a.txt |",
      "$CAT a.txt",
    }) do
      assert.are.same({}, reads(line), line)
    end
    assert.are.same({ { path = a } }, reads("cat missing.txt a.txt"), "the files that exist")
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

  it("skips context lines and group separators", function()
    assert.are.same(
      { { path = a, line = 2 }, { path = a, line = 5 } },
      hits("grep -n -A1 line a.txt", "2:line 2\n3-line 3\n--\n5:line 5\n6-line 6")
    )
    assert.are.same(
      { { path = c, line = 2 }, { path = a, line = 5 } },
      hits("grep -rn -B1 line sub a.txt", "sub/c.txt-1-x\nsub/c.txt:2:y\n--\na.txt-4-z\na.txt:5:w")
    )
  end)

  it("stops at the first line that is no hit", function()
    assert.are.same(
      { { path = a, line = 2 } },
      hits("grep -n line a.txt | head -60; echo ---; grep -n x b.txt", "2:line 2\n---\n1:x")
    )
    assert.are.same({}, hits("grep -n line a.txt", "Binary file a.txt matches\n2:line 2"))
  end)

  it("skips the exit code and the errors at the start of a failed call's text", function()
    assert.are.same(
      { { path = a, line = 7 }, { path = a, line = 8 } },
      hits(
        "cd sub && grep -rn line .. nothere",
        "Exit code 2\nugrep: warning: nothere: No such file or directory\n../a.txt:7:line 7\n../a.txt:8:line 8"
      )
    )
  end)

  it("finds the hits after an echo's separator", function()
    assert.are.same({ { path = a, line = 2 } }, hits("ls; echo ---; grep -n line a.txt", "a.txt\nb.txt\n---\n2:line 2"))
    assert.are.same(
      { { path = c, line = 4 } },
      hits("grep -ril line . | head -80; echo ---; grep -rn line sub", "a.txt\nsub/c.txt\n---\nsub/c.txt:4:line 4")
    )
    assert.are.same(
      { { path = b, line = 1 } },
      hits("echo ---; ls; echo ---; grep -n line b.txt", "---\na.txt\n---\n1:line 1")
    )
    assert.are.same({}, hits("ls; echo ---; grep -n line a.txt", "a.txt\nb.txt"), "no separator")
  end)

  it("follows cd and keeps the lines that filters let through", function()
    assert.are.same({ { path = c, line = 4 } }, hits("cd sub && grep -n line c.txt", "4:line 4"))
    assert.are.same(
      { { path = c, line = 4 } },
      hits("grep -rn line . 2>/dev/null | grep -v test | head -30", "sub/c.txt:4:line 4")
    )
    assert.are.same({ { path = a, line = 2 } }, hits("grep -rn --include=*.txt line . | sort", "a.txt:2:line 2"))
  end)

  it("gives no grep for output without line numbers", function()
    for _, line in ipairs({
      "grep line a.txt",
      "grep -l line .",
      "grep -rln line .",
      "grep -c line a.txt",
      "grep -L line a.txt",
      "grep -v line a.txt",
      "grep -rnl line .",
      "rg line",
      "rg -n -N line",
      "rg -n --heading line",
      "ls; grep -n line a.txt",
      "grep -n line a.txt > out.txt",
      "grep -rn line . | wc -l",
      "grep -rn line . | cut -d: -f1",
      "grep -rn line . | grep -c x",
      "grep -rn line . | grep x b.txt",
      "grep -n $PAT $(ls)",
    }) do
      assert.is_nil(bashread.grep(line, dir), line)
    end
  end)

  it("gives no grep of one file when a later command can print lines that look like its hits", function()
    for _, line in ipairs({
      "grep -n line a.txt; grep -n line b.txt",
      "grep -n line a.txt || grep -n line b.txt",
      "grep -n line a.txt; rg -n line b.txt",
      "grep -n line a.txt && echo ---; grep -n line b.txt",
      "grep -n line a.txt; echo 7:x",
      "grep -n line a.txt; ls",
    }) do
      assert.is_nil(bashread.grep(line, dir), line)
    end
    for _, line in ipairs({
      "grep -n line a.txt; echo ---; grep -n line b.txt",
      "grep -n line a.txt; cd sub; echo ---; ls",
      "grep -rn line .; grep -rn line sub",
    }) do
      assert.is_table(bashread.grep(line, dir), line)
    end
    assert.are.same(
      { { path = a, line = 2 } },
      hits("grep -n line a.txt; echo ---; grep -n line b.txt", "2:line 2\n---\n7:line 7")
    )
  end)

  it("takes -NUM as context for grep, and refuses rg's -0", function()
    assert.is_true(bashread.grep("grep -n -2 line a.txt", dir).context)
    assert.is_nil(bashread.grep("rg -n -0 line", dir))
    assert.is_nil(bashread.grep("grep -n line a.txt &", dir), "a grep in the background")
  end)

  it("needs a file for hits without a path", function()
    assert.are.same({}, hits("grep -n line", "2:line 2"), "stdin")
    assert.are.same({}, hits("grep -hn line a.txt b.txt", "2:line 2"), "-h with several files")
    assert.are.same({ { path = a, line = 2 } }, hits("grep -vn x a.txt", "2:line 2"))
  end)
end)
