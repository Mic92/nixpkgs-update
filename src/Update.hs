{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}

module Update
  ( updateAll
  ) where

import           Check (checkResult)
import           Clean (fixSrcUrl)
import           Control.Exception (SomeException, throw, toException)
import           Control.Monad (forM_)
import           Control.Monad.Except (MonadError, ExceptT (..), throwError, runExceptT)
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Reader (MonadReader (..), runReaderT)
import           Data.Maybe (fromMaybe)
import           Data.Semigroup ((<>))
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Time.Clock (getCurrentTime)
import           Data.Time.Format (defaultTimeLocale, formatTime, iso8601DateFormat)
import qualified File
import           Git
  ( autoUpdateBranchExists
  , checkoutAtMergeBase
  , cleanAndResetToMaster
  , cleanAndResetToStaging
  , cleanup
  , fetchIfStale
  , push
  , commit
  , pr
  )
import           Monad (M (..), UpdateEnv (..))
import           NeatInterpolation (text)
import           Shelly
  ( ShellyHandler (..)
  )
import           Shelly.Lifted
  ( liftSh
  , MonadSh
  , cmd
  , when
  , Sh (..)
  , sleep
  , (-|-)
  , sub
  , fromText
  , whenM
  , unless
  , catches_sh
  , catch_sh
  , mkdir_p
  , appendfile
  , readfile
  , touchfile
  , readfile
  , (</>)
  , toTextIgnore
  , shelly
  )
import           Utils
  ( ExitCode(..)
  , Options(..)
  , Version
  , canFail
  , checkAttrPathVersion
  , orElse
  , parseUpdates
  , setupNixpkgs
  , tRead
  )

default (T.Text)

errorExit :: M m => Text -> m a
errorExit message = do
  bn <- askBranchName
  liftSh $ cleanup bn
  throwError message

nameBlackList :: [(Text -> Bool, Text)]
nameBlackList =
  [ (("jquery" `T.isInfixOf`), "this isn't a real package")
  , (("google-cloud-sdk" `T.isInfixOf`), "complicated package")
  , (("github-release" `T.isInfixOf`), "complicated package")
  , (("fcitx" `T.isInfixOf`), "gets stuck in daemons")
  , ( ("libxc" `T.isInfixOf`)
    , "currently people don't want to update this https://github.com/NixOS/nixpkgs/pull/35821")
  , (("perl" `T.isInfixOf`), "currently don't know how to update perl")
  , (("python" `T.isInfixOf`), "currently don't know how to update python")
  , (("cdrtools" `T.isInfixOf`), "We keep downgrading this by accident.")
  , (("gst" `T.isInfixOf`), "gstreamer plugins are kept in lockstep.")
  , (("electron" `T.isInfixOf`), "multi-platform srcs in file.")
  , ( ("linux-headers" `T.isInfixOf`)
    , "Not updated until many packages depend on it (part of stdenv).")
  , ( ("mpich" `T.isInfixOf`)
    , "Reported on repology.org as mischaracterized newest version")
  , (("xfce" `T.isInfixOf`), "@volth asked to not update xfce")
  , (("cmake-cursesUI-qt4UI" `T.isInfixOf`), "Derivation file is complicated")
  , ( ("varnish" `T.isInfixOf`)
    , "Temporary blacklist because of multiple versions and slow nixpkgs update")
  , (("iana-etc" `T.isInfixOf`), "@mic92 takes care of this package")
  , (("checkbashism" `T.isInfixOf`), "needs to be fixed, see https://github.com/NixOS/nixpkgs/pull/39552")
  , ((== "isl"), "multi-version long building package")
  , ((== "tokei"), "got stuck forever building with no CPU usage")
  , (("qscintilla" `T.isInfixOf`), "https://github.com/ryantm/nixpkgs-update/issues/51")
  ]

contentBlacklist :: [(Text, Text)]
contentBlacklist =
  [ ("DO NOT EDIT", "Derivation file says not to edit it.")
    -- Skip packages that have special builders
  , ("buildGoPackage", "Derivation contains buildGoPackage.")
  , ("buildRustCrate", "Derivation contains buildRustCrate.")
  , ("buildPythonPackage", "Derivation contains buildPythonPackage.")
  , ("buildRubyGem", "Derivation contains buildRubyGem.")
  , ("bundlerEnv", "Derivation contains bundlerEnv.")
  , ("buildPerlPackage", "Derivation contains buildPerlPackage.")
  ]

nixEval :: M m => Text -> m Text
nixEval expr =
  (T.strip <$> cmd "nix" "eval" "-f" "." expr) `orElse`
  errorExit ("nix eval failed for " <> expr)

rawEval :: M m => Text -> m Text
rawEval expr =
  (T.strip <$> (liftSh $ cmd "nix" "eval" "-f" "." "--raw" expr)) `orElse`
  errorExit ("raw nix eval failed for " <> expr)

log' logFile msg
    -- TODO: switch to Data.Time.Format.ISO8601 once time-1.9.0 is available
 = do
  runDate <-
    T.pack . formatTime defaultTimeLocale (iso8601DateFormat (Just "%H:%M:%S")) <$>
    liftIO getCurrentTime
  appendfile logFile (runDate <> " " <> msg <> "\n")

updateAll :: Options -> Sh ()
updateAll options = do
  let logFile = workingDir options </> "ups.log"
  mkdir_p (workingDir options)
  touchfile logFile
  updates <- readfile "packages-to-update.txt"
  let log = log' logFile
  appendfile logFile "\n\n"
  log "New run of ups.sh"
  updateLoop options log (parseUpdates updates)

instance MonadSh m => MonadSh (ExceptT e m) where
    liftSh m = ExceptT $ do
        a <- liftSh m
        return (Right a)

updateLoop ::
     Options
  -> (Text -> Sh ())
  -> [Either Text (Text, Version, Version)]
  -> Sh ()
updateLoop _ log [] = log "ups.sh finished"
updateLoop options log (Left e:moreUpdates) = do
  log e
  updateLoop options log moreUpdates
updateLoop options log (Right (package, oldVersion, newVersion):moreUpdates) = do
  log (package <> " " <> oldVersion <> " -> " <> newVersion)
  let env = UpdateEnv package oldVersion newVersion options

  result <- runExceptT (runReaderT (shelly updatePackage) env)
  case result of
    Left error -> log error >> log "FAIL"
    Right () -> log "SUCCESS"
  updateLoop options log moreUpdates

askBranchName :: MonadReader UpdateEnv m => m Text
askBranchName = do
  updateEnv <- ask
  return $ "auto-update/" <> packageName updateEnv

askOptions :: MonadReader UpdateEnv m => m Options
askOptions = options <$> ask

askPackageName :: MonadReader UpdateEnv m => m Text
askPackageName = packageName <$> ask

askNewVersion :: MonadReader UpdateEnv m => m Version
askNewVersion = newVersion <$> ask

askOldVersion :: MonadReader UpdateEnv m => m Version
askOldVersion = oldVersion <$> ask

updatePackage :: M m => m ()
updatePackage = do
  liftSh setupNixpkgs
  branchName <- askBranchName
  options <- askOptions
  packageName <- askPackageName
  newVersion <- askNewVersion
  oldVersion <- askOldVersion
  -- Check whether requested version is newer than the current one
  versionComparison <-
    nixEval
      ("(builtins.compareVersions \"" <> newVersion <> "\" \"" <> oldVersion <>
       "\")")
  unless (versionComparison == "1") $
    errorExit $
    newVersion <> " is not newer than " <> oldVersion <>
    " according to Nix; versionComparison: " <>
    versionComparison
  -- Check whether package name is on blacklist
  forM_ nameBlackList $ \(isBlacklisted, message) ->
    when (isBlacklisted packageName) $ errorExit message
  fetchIfStale
  whenM
    (liftSh $ autoUpdateBranchExists packageName)
    (errorExit "Update branch already on origin.")
  cleanAndResetToMaster
    -- This is extremely slow but will give us better results
  attrPath <-
    head . T.words . head . T.lines <$>
    cmd
      "nix-env"
      "-qa"
      (packageName <> "-" <> oldVersion)
      "-f"
      "."
      "--attr-path" `orElse`
    errorExit "nix-env -q failed to find package name with old version"
    -- Temporarily blacklist gnome sources for lockstep update
  whenM
    (("gnome" `T.isInfixOf`) <$> nixEval ("pkgs." <> attrPath <> ".src.urls"))
    (errorExit "Packages from gnome are currently blacklisted.")
    -- Temporarily blacklist lua packages at @teto's request
    -- https://github.com/NixOS/nixpkgs/pull/37501#issuecomment-375169646
  when (T.isPrefixOf "lua" attrPath) $
    errorExit "Packages for lua are currently blacklisted."
  derivationFile <-
    fromText . T.strip <$>
    cmd "env" "EDITOR=echo" "nix" "edit" attrPath "-f" "." `orElse`
    errorExit "Couldn't find derivation file."

  numberOfFetchers <-
    tRead <$>
    canFail
      (cmd
         "grep"
         "-Ec"
         "fetchurl {|fetchgit {|fetchFromGitHub {"
         derivationFile)
  unless ((numberOfFetchers :: Int) <= 1) $
    errorExit $ "More than one fetcher in " <> toTextIgnore derivationFile
  derivationContents <- readfile derivationFile
  forM_ contentBlacklist $ \(offendingContent, message) ->
    when (offendingContent `T.isInfixOf` derivationContents) $
    errorExit message
  unless (checkAttrPathVersion attrPath newVersion) $
    errorExit
      ("Version in attr path " <> attrPath <> " not compatible with " <>
       newVersion)
  -- Make sure it hasn't been updated on master
  cmd "grep" oldVersion derivationFile `orElse`
    errorExit "Old version not present in master derivation file."
  -- Make sure it hasn't been updated on staging
  cleanAndResetToStaging
  cmd "grep" oldVersion derivationFile `orElse`
    errorExit "Old version not present in staging derivation file."
  checkoutAtMergeBase branchName
  oldHash <-
    rawEval ("pkgs." <> attrPath <> ".src.drvAttrs.outputHash") `orElse`
    errorExit
      ("Could not find old output hash at " <> attrPath <>
       ".src.drvAttrs.outputHash.")
  oldSrcUrl <-
    rawEval
      ("(let pkgs = import ./. {}; in builtins.elemAt pkgs." <> attrPath <>
       ".src.drvAttrs.urls 0)")
  File.replace oldVersion newVersion derivationFile
  newSrcUrl <-
    rawEval
      ("(let pkgs = import ./. {}; in builtins.elemAt pkgs." <> attrPath <>
       ".src.drvAttrs.urls 0)")
  when (oldSrcUrl == newSrcUrl) $ errorExit "Source url did not change."
  newHash <-
    canFail (T.strip <$> cmd "nix-prefetch-url" "-A" (attrPath <> ".src")) `orElse`
    fixSrcUrl
      packageName
      oldVersion
      newVersion
      derivationFile
      attrPath
      oldSrcUrl `orElse`
    errorExit "Could not prefetch new version URL."
  when (oldHash == newHash) $ errorExit "Hashes equal; no update necessary"
  File.replace oldHash newHash derivationFile
  cmd
    "nix-build"
    "--option" "sandbox" "true"
    "--option" "restrict-eval" "true"
    "-A" attrPath `orElse` do
    buildLog <-
      T.unlines . reverse . take 30 . reverse . T.lines <$>
      cmd "nix" "log" "-f" "." attrPath
    errorExit ("nix build failed.\n" <> buildLog)
  result <-
    fromText <$>
    (T.strip <$>
     (cmd "readlink" "./result" `orElse` cmd "readlink" "./result-bin")) `orElse`
    errorExit "Could not find result link."
  resultCheckReport <- sub (checkResult options result newVersion)
  maintainers <-
    rawEval
      ("(let pkgs = import ./. {}; gh = m : m.github or \"\"; nonempty = s: s != \"\"; addAt = s: \"@\"+s; in builtins.concatStringsSep \" \" (map addAt (builtins.filter nonempty (map gh pkgs." <>
       attrPath <>
       ".meta.maintainers or []))))")
  let maintainersCc =
        if not (T.null maintainers)
          then "\n\ncc " <> maintainers <> " for review"
          else ""
  let commitMessage =
        [text|
              $attrPath: $oldVersion -> $newVersion

              Semi-automatic update generated by https://github.com/ryantm/nixpkgs-update tools.

              This update was made based on information from https://repology.org/metapackage/$packageName/versions.

              These checks were done:

              - built on NixOS
              $resultCheckReport
          |]
  commit commitMessage
  -- Try to push it three times
  push branchName options `orElse` push branchName options `orElse`
    push branchName options
  isBroken <-
    nixEval
      ("(let pkgs = import ./. {}; in pkgs." <> attrPath <>
       ".meta.broken or false)")
  let brokenWarning =
        if isBroken == "true"
          then "- WARNING: Package has meta.broken=true; Please manually test this package update and remove the broken attribute."
          else ""
  let prMessage = commitMessage <> brokenWarning <> maintainersCc
  untilOfBorgFree
  pr prMessage
  cleanAndResetToMaster

untilOfBorgFree :: Sh ()
untilOfBorgFree = do
  waiting :: Int <-
    tRead <$>
    canFail
      (cmd "curl" "-s" "https://events.nix.ci/stats.php" -|-
       cmd "jq" ".evaluator.messages.waiting")
  when (waiting > 2) $ do
    sleep 60
    untilOfBorgFree
