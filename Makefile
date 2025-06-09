DOCS := $(shell find chapters -name "*.typ"|sort -d)

pdf: 
	@typst compile main.typ
	

watch: docs-all
	@typst watch main.typ
	
docs-all:
	@ > doc-all.typ
	@for file in $(DOCS); do \
  		echo "#include \"$$file\"" >> doc-all.typ; \
	done

clean:
	@rm -rf *.pdf
	@rm -rf doc-all.typ
	@rm -rf chapters/*.pdf

format-lint:
	@autocorrect --lint *.typ $(DOCS)	
format-fix:
	@autocorrect --fix *.typ $(DOCS)
