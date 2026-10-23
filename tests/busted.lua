---@meta
--# selene: allow(unused_variable)
-- mini.test defines these busted globals when it runs the specs. This file
-- only declares them for lua-language-server.

---@param name string
---@param fn fun()
function describe(name, fn) end

---@param name string
---@param fn fun()
function it(name, fn) end

---@param fn fun()
function before_each(fn) end

---@param fn fun()
function after_each(fn) end
