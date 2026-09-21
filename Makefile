.PHONY: setup test lint type fix complexity ci e2e

ROCKSPEC := vim-diffundo-dev-1.rockspec
LUAROCKS := luarocks --tree lua_modules
ROCKS := eval $$($(LUAROCKS) path --bin) &&
SRC := lua plugin spec

# The denops.vim checkout @denops/test drives the editor with; see tests/e2e/.
DENOPS_VERSION = v8.0.2
DENOPS_PATH = $(CURDIR)/.cache/denops.vim
# tpope/vim-repeat, so the e2e suite can press . after a diffundo command.
REPEAT_VERSION = v1.2
REPEAT_PATH = $(CURDIR)/.cache/vim-repeat

setup:
	$(LUAROCKS) install --only-deps $(ROCKSPEC)
	$(LUAROCKS) install busted
	$(LUAROCKS) install luacov

test:
	$(ROCKS) busted
	@sed -n '/^Summary/,$$p' luacov.report.out

lint:
	selene $(SRC)
	stylua --check $(SRC)
	ast-grep scan $(SRC)

fix:
	-ast-grep scan --update-all $(SRC)
	stylua $(SRC)

type:
	lua-language-server --check . --checklevel=Warning --logpath=.luals --configpath=.luarc.json

complexity:
	.github/scripts/check_complexity.sh

$(DENOPS_PATH):
	git clone --depth 1 --branch $(DENOPS_VERSION) https://github.com/vim-denops/denops.vim $(DENOPS_PATH)

$(REPEAT_PATH):
	git clone --depth 1 --branch $(REPEAT_VERSION) https://github.com/tpope/vim-repeat $(REPEAT_PATH)

e2e: $(DENOPS_PATH) $(REPEAT_PATH)
	cd tests/e2e && DENOPS_TEST_DENOPS_PATH=$(DENOPS_PATH) deno test -A

ci: test lint type complexity
