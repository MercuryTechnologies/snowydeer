-- SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
--
-- SPDX-License-Identifier: MIT OR Apache-2.0
{-# LANGUAGE QuasiQuotes #-}

module Snowydeer.Container.PipelineSpec where

import Data.Aeson qualified as A
import RIO
import Snowydeer.Container.Pipeline
import Test.Hspec
import Text.Shakespeare.Text (st)

toJSONEquiv :: A.ToJSON v => Text -> v -> Expectation
toJSONEquiv sample value =
  let expected = either error id $ A.eitherDecodeStrictText sample
      actual = A.toJSON value
   in A.encode @A.Value actual `shouldBe` A.encode @A.Value expected

spec :: Spec
spec = do
  describe "encoding" do
    -- https://github.com/NixOS/nixpkgs/blob/f720de59066162ee879adcc8c79e15c51fe6bfb4/pkgs/by-name/fl/flattenReferencesGraph/src/flatten_references_graph/pipe_test.py#L55-L74
    it "pipe_test test_1" $
      [st| [
              ["split_paths", ["B"]],
              [
                  "over",
                  "main",
                  [
                      "pipe",
                      [
                          ["subcomponent_in", ["B"]],
                          [
                              "over",
                              "rest",
                              ["popularity_contest"]
                          ]
                      ]
                  ]
              ],
              ["flatten"],
              ["map", ["remove_paths", ["Root3"]]],
              ["limit_layers", 5]
          ] |]
        <~> [ SplitPaths ["B"]
            , Over "main" $
                Pipe
                  [ SubcomponentIn ["B"]
                  , Over "rest" PopularityContest
                  ]
            , Flatten
            , Map (RemovePaths ["Root3"])
            , LimitLayers 5
            ]

    -- https://github.com/adrian-gierakowski/nix-docker-custom-layering-strategy-example/blob/781b5e2184a5c8a1e2e67dc79c569adf4b6e6581/default.nix#L66
    it "nix-docker-custom-layering-strategy-example" $
      [st|
        [
          [ "subcomponent_out", [ "python3" ] ],
          [
            "over",
            "rest",
            [
              "pipe",
              [
                [ "split_paths", [ "alerta" ] ],
                [
                  "over",
                  "main",
                  [
                    "pipe",
                    [
                      [ "subcomponent_in", [ "alerta" ] ],
                      [
                        "over",
                        "rest",
                        [
                          "pipe",
                          [
                            [ "popularity_contest" ],
                            [ "reverse" ],
                            [ "limit_layers", 110 ]
                          ]
                        ]
                      ]
                    ]
                  ]
                ],
                [
                  "over",
                  "rest",
                  [
                    "pipe",
                    [
                      [ "subcomponent_in", [ "with-env-from-dir" ] ],
                      [
                        "over",
                        "rest",
                        [ "subcomponent_in", [ "cacert" ] ]
                      ]
                    ]
                  ]
                ]
              ]
            ]
          ]
        ]
      |]
        <~> [ SubcomponentOut ["python3"]
            , Over "rest" $
                Pipe
                  [ SplitPaths ["alerta"]
                  , Over "main" $
                      Pipe
                        [ SubcomponentIn ["alerta"]
                        , Over "rest" $
                            Pipe
                              [ PopularityContest
                              , Reverse
                              , LimitLayers 110
                              ]
                        ]
                  , Over "rest" $
                      Pipe
                        [ SubcomponentIn ["with-env-from-dir"]
                        , Over "rest" $ SubcomponentIn ["cacert"]
                        ]
                  ]
            ]

  describe "our own images" do
    it "manual example snapshot" do
      pipelineFor ["a", "b", "c"]
        `shouldBe` [ Over "rest" . Pipe $
                       [ SubcomponentOut ["a", "b", "c"]
                       , Over "main" . Pipe $
                           [ SubcomponentIn ["a"]
                           , Over "rest" . Pipe $
                               [ SubcomponentIn ["b"]
                               , Over "rest" . Pipe $
                                   [ SubcomponentIn ["c"]
                                   , Over "rest" $ Pipe [PopularityContest, Reverse, LimitLayers 90]
                                   ]
                               ]
                           ]
                       , Over "rest" $ Pipe [PopularityContest, Reverse, LimitLayers 30]
                       ]
                   ]
  where
    a <~> b = toJSONEquiv a b

main :: IO ()
main = hspec spec
