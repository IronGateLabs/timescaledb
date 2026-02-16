MODULE_big = timescaledb_gpu_bridge
OBJS = gpu_bridge.o arrow_kds.o gpu_dispatch.o cost_model.o

EXTENSION = timescaledb_gpu_bridge
DATA = timescaledb_gpu_bridge--1.0.sql

REGRESS = gpu_bridge_noop

PG_CPPFLAGS = -I$(srcdir) -I$(srcdir)/../tsl/src
SHLIB_LINK =

ifdef ENABLE_DEBUG
PG_CPPFLAGS += -DUSE_ASSERT_CHECKING
endif

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
