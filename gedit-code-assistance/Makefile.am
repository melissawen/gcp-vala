SUBDIRS = data src vapi backends

ACLOCAL_AMFLAGS = -I m4

MAINTAINERCLEANFILES = 			\
	aclocal.m4			\
	config.guess			\
	config.h.in			\
	config.sub			\
	depcomp				\
	gedit-code-assistance.doap	\
	gtk-doc.make			\
	install-sh			\
	ltmain.sh			\
	missing				\
	mkinstalldirs			\
	omf.make			\
	py-compile			\
	m4/libtool.m4			\
	m4/ltoptions.m4			\
	m4/ltsugar.m4			\
	m4/ltversion.m4			\
	m4/lt~obsolete.m4		\
	`find "$(srcdir)" -type f -name Makefile.in -print`

dist-hook:
	@if test -d "$(srcdir)/.git"; \
	then \
		echo Creating ChangeLog && \
		(GIT_DIR=$(top_srcdir)/.git \
		  ./missing --run git log --stat -M -C --name-status  --date=short --no-color) | \
		  fmt --split-only > ChangeLog.tmp \
		&& mv -f ChangeLog.tmp $(top_distdir)/ChangeLog \
		|| ( rm -f ChangeLog.tmp ; \
		  echo Failed to generate ChangeLog >&2 ); \
	else \
		echo A git clone is required to generate a ChangeLog >&2; \
	fi

-include $(top_srcdir)/git.mk
