# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Defaults for Haskell compiler flags.
"""

default_extensions = [
    "Haskell2010",
    # keep-sorted start
    "BangPatterns",
    "BlockArguments",
    "DataKinds",
    "DefaultSignatures",
    "DeriveAnyClass",
    "DeriveFunctor",
    "DeriveGeneric",
    "DeriveLift",
    "DeriveTraversable",
    "DerivingStrategies",
    "DerivingVia",
    "FlexibleContexts",
    "FlexibleInstances",
    "GADTs",
    "GeneralizedNewtypeDeriving",
    "ImportQualifiedPost",
    "InstanceSigs",
    "LambdaCase",
    "LexicalNegation",
    "MultiParamTypeClasses",
    "MultiWayIf",
    "NamedFieldPuns",
    "NegativeLiterals",
    "NoForeignFunctionInterface",  # For some reason this is on by default???! It makes `label` a reserved word.
    "NoImplicitPrelude",
    "NumericUnderscores",
    "OverloadedLabels",
    "OverloadedRecordDot",
    "OverloadedStrings",
    "PartialTypeSignatures",
    "PatternSynonyms",
    "RankNTypes",
    "RecordWildCards",
    "RoleAnnotations",
    "ScopedTypeVariables",
    "StandaloneDeriving",
    "TypeApplications",
    "TypeFamilies",
    "TypeOperators",
    "UndecidableInstances",
    "ViewPatterns",
    # keep-sorted end
]

default_ghc_flags = ["-X" + ext for ext in default_extensions] + [
    # Fully deterministic build
    # TODO: Enforce this at rules level.
    "-fobject-determinism",
    #
    "-Werror",
    "-Weverything",
    "-Wno-missing-exported-signatures",  # missing-exported-signatures turns off the more strict -Wmissing-signatures. See https://ghc.haskell.org/trac/ghc/ticket/14794#ticket
    "-Wno-missing-export-lists",  # Requires explicit export lists for every module, a pain for large modules
    "-Wno-missing-import-lists",  # Requires explicit imports of _every_ function (e.g. '$'); too strict
    "-Wno-missed-specialisations",  # When GHC can't specialize a polymorphic function. No big deal and requires fixing underlying libraries to solve.
    "-Wno-all-missed-specialisations",  # See missed-specialisations
    "-Wno-unsafe",  # Don't use Safe Haskell warnings
    "-Wno-missing-local-signatures",  # Warning for polymorphic local bindings. Don't think this is an issue
    "-Wno-monomorphism-restriction",  # Don't warn if the monomorphism restriction is used
    "-Wno-missing-safe-haskell-mode",  # Cabal isn’t setting this currently (introduced in GHC 8.10)
    "-Wno-unused-packages",  # Some tooling gives this error
    "-Wno-operator-whitespace",  # GHC bug? https://gitlab.haskell.org/ghc/ghc/-/issues/23297
    "-Wno-missing-kind-signatures",  # Noisy
    "-Wno-ambiguous-fields",  # Combines poorly with DuplicateRecordFields

    # GHC 9.10+:
    # GHC >= 9.8 is stricter.
    "-Wno-missing-role-annotations",  # Not warning about role annotation when defining newtype.
    "-Wno-term-variable-capture",  # Not warning about name conflict between type and term variables.
    "-Wno-missing-poly-kind-signatures",  # Not warning about poly-kind type definitions without kind signature.
    "-Wno-x-partial",  # Not warning about partial functions
    # Unfixable error:
    #
    #     Solving for an implicit ExceptionContext constraint
    #       arising from a use of ‘SomeException’.
    #     Future versions of GHC will turn this warning into an error.
    #     See GHC Proposal #330.
    #
    # If you add a `(?ctx :: ExceptionContext)` constraint, you instead get
    # _this_ error:
    #
    #     • Redundant constraint: ?ctx::ExceptionContext
    #       In the type signature for:
    #            handler :: (?ctx::ExceptionContext) =>
    #                       SomeException -> HttpExecutionException
    "-Wno-defaulted-exception-context",
    "-fwarn-tabs",  # no tabs in source files
    "-fdefer-diagnostics",  # Print diagnostics at the *end* of the build so they're not in 10k lines of junk
    "-fdiagnostics-color=always",  # Enable color

    # -haddock adds Haddock to interface files, allowing us to pull
    # documentation in TH - needed for things like generating golden types.
    "-haddock",
]
