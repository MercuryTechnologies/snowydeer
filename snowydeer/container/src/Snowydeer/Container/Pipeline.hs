-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0

-- | Fine-grained layering control.
module Snowydeer.Container.Pipeline where

import Data.Aeson qualified as A
import RIO
import Snowydeer.Container.Types

-- | The undocumented layering pipeline from <https://github.com/NixOS/nixpkgs/pull/122608>.
--
-- This is a galaxy brained point-free pipeline encoded in JSON, used by Python.
-- It's commendable in its flexibility but the intended way to write it (ie not
-- in Haskell) is not very easy to read or get right without some smart
-- constructors or types to encode each operation's arity.
--
-- Each item in here is an atom which is represented as @[item]@ in the output.
data PipelineItem
  = -- | Splits the incoming graph into a list of subgraphs.
    -- Tail type: @Graph -> [Graph]@.
    SplitEvery Int
  | -- | Grabs the first N items in the list and then splats the rest into one flat list.
    -- Tail type: @[Graph] -> [Graph]@.
    LimitLayers Int
  | -- | Flattens arbitrarily nested lists into one list and turns dicts into lists.
    -- Note that dicts are all in the order (main, common, rest), and are
    -- flattened in an according order; the sort order of python dicts is
    -- load-bearing to this program.
    --
    -- Does not flatten graphs.
    -- Used to delete the nesting that graphs are in.
    --
    -- Tail type: @[[a]] -> [a]@ (for any number of nested @[]@).
    Flatten
  | -- | Calls func (arg 2) with the value of prop (arg 1) extracted from the dictionary in the input.
    -- In practice this is used to map over the "main", "common", "rest" tuples that come
    -- out of 'SubcomponentIn', 'SubcomponentOut', 'SplitPaths'.
    --
    -- Tail type: @a -> b@
    Over Text PipelineItem
  | -- | @foldr (.) id@. Tail type: @a -> b@.
    Pipe [PipelineItem]
  | -- | Finds paths from the given list and removes them from the list.
    -- Tail type: @Graph -> Graph@
    RemovePaths [StorePath]
  | -- | Reverses a list. Tail type: @[a] -> [a]@
    Reverse
  | -- | Sorts the graph by popularity of paths.
    -- Produces a list of 1-node graphs by popularity.
    --
    -- Tail type: @Graph -> [Graph]@
    PopularityContest
  | -- | Partitions out the part of the graph which has incoming
    -- dep edges to the given nodes, transitively. Tail type:
    -- @[Graph] -> {"main": ..., "rest": ...}@.
    --
    -- For example if you used this on some image library, it would put in the
    -- main section: that image library, a graph viewer depending on it, and a
    -- program that depends on that graph viewer for debug visualization.
    SubcomponentIn [StorePath]
  | -- | Partitions out the part of the graph which has outgoing dep edges to
    -- the given nodes, transitively.
    -- Tail type: @[Graph] -> {"main": ..., "rest": ...}@
    --
    -- For example, if you used this on python, it might put python, glibc and sqlite
    -- in the main set.
    SubcomponentOut [StorePath]
  | -- | Splits graph.
    -- Cuts incoming edges to each node in the arguments, then partitions the
    -- graph into edges only accessible via something in the arg nodes (main),
    -- edges which are accessible via other paths in the graph in addition to the
    -- arg nodes (common), and edges which are not accessible from the arg nodes (rest).
    --
    -- For example, this could be used to rip out, say, python and all the
    -- dependencies it is the sole cause of into their own layer by themselves.
    -- Unlike SubcomponentOut, this distinguishes whether dependencies are
    -- *solely* caused by the store paths in the arg nodes.
    -- Tail type: @[Graph] -> {"main": [Self, *OwnDeps], "common": SharedDeps, "rest": OtherPaths}@.
    SplitPaths [StorePath]
  | -- | @map Func@. Tail type: @a -> b@.
    Map PipelineItem
  deriving stock (Show, Eq)

instance A.ToJSON PipelineItem where
  toJSON =
    A.toJSONList . \case
      SplitEvery n -> ["split_every", A.toJSON n]
      LimitLayers n -> ["limit_layers", A.toJSON n]
      Flatten -> ["flatten"]
      Over attr func -> ["over", A.String attr, A.toJSON func]
      RemovePaths ps -> ["remove_paths", A.toJSON ps]
      Reverse -> ["reverse"]
      PopularityContest -> ["popularity_contest"]
      Pipe pipeline -> ["pipe", A.toJSON pipeline]
      SubcomponentIn paths -> ["subcomponent_in", A.toJSON paths]
      SubcomponentOut paths -> ["subcomponent_out", A.toJSON paths]
      SplitPaths paths -> ["split_paths", A.toJSON paths]
      Map f -> ["map", A.toJSON f]

-- Note [Layering Strategy]:
-- The name of the game here is to have *what* goes into each layer be likely
-- to be the same across runs.
--
-- As such, we have this `mainContents` list which drives the layering
-- strategy: each path in there will be assigned its own layer.
-- Then, all the dependencies of all `mainContents` are put into their own
-- layers based on a combined metric of how high they are in the dep graph/how
-- common they are and thus how likely they are to have changes to them without
-- invalidating the whole image.
--
-- All the least likely to change dependencies of `mainContents` get squashed
-- into one layer if we don't have layer budget for them.
--
-- For all the paths in `contents` but not in `mainContents`, those are handled
-- with a similar procedure and appended on the end of the list of layers from
-- `mainContents`.

-- | Makes a pipeline for the given mainContents.
--
-- See Note [Layering strategy] for more on why this works the way it is.
pipelineFor :: [StorePath] -> [PipelineItem]
pipelineFor mainContents =
  [ -- Incoming input from build-container.nix: (main, rest) tuple for the stuff
    -- in the base of the image.
    Over "rest" $
      Pipe
        -- Select the set of things depended on by the main contents (the
        -- application, probably).
        [ SubcomponentOut mainContents
        , Over "main" $ mainPipeline mainContents
        , -- Handle things in `contents` but not `mainContents`, and their
          -- dependencies that are not depended on by `mainContents`.
          Over "rest" $ Pipe [PopularityContest, Reverse, LimitLayers 30]
        ]
  ]
  where
    eachPath path pipeline =
      Pipe
        -- If you think about it, SubcomponentIn will *only* extract `path`, since
        -- all the incoming edges of the blob of main contents have been sliced out
        -- already. This might not be true for interdependencies within this
        -- list that are included out of dependency order in our input, but
        -- those aren't too important.
        [ SubcomponentIn [path]
        , Over "rest" pipeline
        ]

    mainPipeline :: [StorePath] -> PipelineItem
    mainPipeline = foldr eachPath $ Pipe [PopularityContest, Reverse, LimitLayers 90]
