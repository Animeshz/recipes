.DEFAULT_GOAL := all

.PHONY: all
all:
	@printf '%s\n' $(sort $(basename $(notdir $(wildcard recipes/*.ncl))))

%: recipes/%.ncl
	@nickel export --format=json recipes/$@.ncl | jq -r .plan | bash
