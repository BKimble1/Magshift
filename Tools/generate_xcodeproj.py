#!/usr/bin/env python3
"""Deterministically generate WallField.xcodeproj.

The project uses Xcode 16's file-system-synchronized root groups
(``PBXFileSystemSynchronizedRootGroup``, ``objectVersion = 77``). That means the
three source folders -- ``WallField``, ``WallFieldTests`` and ``WallFieldUITests``
-- are members of their targets by virtue of being on disk. Adding, renaming or
deleting a Swift file never requires touching ``project.pbxproj``, which removes
the single most common way a generated Xcode project rots.

Run ``python3 Tools/generate_xcodeproj.py`` from the repository root to rebuild
the project file from scratch. The output is byte-for-byte stable.
"""

from __future__ import annotations

import hashlib
import os
import sys

OBJECT_VERSION = 77
ORGANIZATION = "Idlery Services LLC"
APP_NAME = "WallField"
UNIT_TESTS = "WallFieldTests"
UI_TESTS = "WallFieldUITests"
DEFAULT_BUNDLE_ID = "com.idlery.wallfield"


def gid(name: str) -> str:
    """Stable 24-character hex identifier derived from a logical name."""
    return hashlib.md5(("wallfield::" + name).encode("utf-8")).hexdigest()[:24].upper()


# --- identifiers -------------------------------------------------------------
ID = {k: gid(k) for k in [
    "project", "rootGroup", "productsGroup", "configGroup", "docsGroup",
    "syncApp", "syncUnitTests", "syncUITests",
    "appTarget", "unitTestTarget", "uiTestTarget",
    "appProduct", "unitTestProduct", "uiTestProduct",
    "appSources", "appFrameworks", "appResources",
    "unitSources", "unitFrameworks", "unitResources",
    "uiSources", "uiFrameworks", "uiResources",
    "projectConfigList", "appConfigList", "unitConfigList", "uiConfigList",
    "projectDebug", "projectRelease",
    "appDebug", "appRelease", "unitDebug", "unitRelease", "uiDebug", "uiRelease",
    "xcconfigDebug", "xcconfigRelease", "xcconfigShared", "xcconfigSigning",
    "infoPlist", "readme",
    "unitDependency", "uiDependency", "unitProxy", "uiProxy",
]}

DOC_FILES = [
    "ARCHITECTURE.md",
    "ALGORITHM.md",
    "SAFETY_AND_LIMITATIONS.md",
    "VALIDATION_PROTOCOL.md",
    "APP_STORE_PREP.md",
    "PRIVACY.md",
]
for doc in DOC_FILES:
    ID["doc::" + doc] = gid("doc::" + doc)


def settings_block(pairs: dict[str, object], indent: str) -> str:
    out = []
    for key in sorted(pairs):
        value = pairs[key]
        if isinstance(value, list):
            out.append(f"{indent}{key} = (")
            for item in value:
                out.append(f'{indent}\t"{item}",')
            out.append(f"{indent});")
        else:
            out.append(f"{indent}{key} = {value};")
    return "\n".join(out)


def quoted(value: str) -> str:
    return '"%s"' % value


SHARED_TEST_SETTINGS = {
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "GENERATE_INFOPLIST_FILE": "YES",
    "MARKETING_VERSION": "1.0.0",
    "PRODUCT_NAME": quoted("$(TARGET_NAME)"),
    "SWIFT_EMIT_LOC_STRINGS": "NO",
}

APP_SETTINGS = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": "Config/WallField-Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
    "MARKETING_VERSION": "1.0.0",
    "PRODUCT_NAME": quoted("$(TARGET_NAME)"),
    "SWIFT_EMIT_LOC_STRINGS": "YES",
}

UNIT_SETTINGS = dict(SHARED_TEST_SETTINGS)
UNIT_SETTINGS.update({
    "BUNDLE_LOADER": quoted("$(TEST_HOST)"),
    "PRODUCT_BUNDLE_IDENTIFIER": f"{DEFAULT_BUNDLE_ID}.unittests",
    "TEST_HOST": quoted("$(BUILT_PRODUCTS_DIR)/WallField.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/WallField"),
})

UI_SETTINGS = dict(SHARED_TEST_SETTINGS)
UI_SETTINGS.update({
    "PRODUCT_BUNDLE_IDENTIFIER": f"{DEFAULT_BUNDLE_ID}.uitests",
    "TEST_TARGET_NAME": APP_NAME,
})


def build_pbxproj() -> str:
    L: list[str] = []
    add = L.append

    add("// !$*UTF8*$!")
    add("{")
    add("\tarchiveVersion = 1;")
    add("\tclasses = {")
    add("\t};")
    add(f"\tobjectVersion = {OBJECT_VERSION};")
    add("\tobjects = {")
    add("")

    # --- PBXFileReference ----------------------------------------------------
    add("/* Begin PBXFileReference section */")
    file_refs = [
        (ID["appProduct"], APP_NAME + ".app", "wrapper.application", "BUILT_PRODUCTS_DIR", None),
        (ID["unitTestProduct"], UNIT_TESTS + ".xctest", "wrapper.cfbundle", "BUILT_PRODUCTS_DIR", None),
        (ID["uiTestProduct"], UI_TESTS + ".xctest", "wrapper.cfbundle", "BUILT_PRODUCTS_DIR", None),
    ]
    for ref_id, name, ftype, tree, _ in file_refs:
        add(f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; explicitFileType = {ftype}; "
            f'includeInIndex = 0; path = "{name}"; sourceTree = {tree}; }};')

    plain_refs = [
        (ID["xcconfigShared"], "Shared.xcconfig", "text.xcconfig"),
        (ID["xcconfigSigning"], "Signing.xcconfig", "text.xcconfig"),
        (ID["xcconfigDebug"], "App-Debug.xcconfig", "text.xcconfig"),
        (ID["xcconfigRelease"], "App-Release.xcconfig", "text.xcconfig"),
        (ID["infoPlist"], "WallField-Info.plist", "text.plist.xml"),
        (ID["readme"], "README.md", "net.daringfireball.markdown"),
    ]
    for doc in DOC_FILES:
        plain_refs.append((ID["doc::" + doc], doc, "net.daringfireball.markdown"))
    for ref_id, name, ftype in plain_refs:
        add(f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; "
            f'path = "{name}"; sourceTree = "<group>"; }};')
    add("/* End PBXFileReference section */")
    add("")

    # --- PBXFileSystemSynchronizedRootGroup ----------------------------------
    add("/* Begin PBXFileSystemSynchronizedRootGroup section */")
    for key, path in [("syncApp", APP_NAME), ("syncUnitTests", UNIT_TESTS), ("syncUITests", UI_TESTS)]:
        add(f"\t\t{ID[key]} /* {path} */ = {{")
        add("\t\t\tisa = PBXFileSystemSynchronizedRootGroup;")
        add(f"\t\t\tpath = {path};")
        add('\t\t\tsourceTree = "<group>";')
        add("\t\t};")
    add("/* End PBXFileSystemSynchronizedRootGroup section */")
    add("")

    # --- PBXFrameworksBuildPhase --------------------------------------------
    add("/* Begin PBXFrameworksBuildPhase section */")
    for key, label in [("appFrameworks", APP_NAME), ("unitFrameworks", UNIT_TESTS), ("uiFrameworks", UI_TESTS)]:
        add(f"\t\t{ID[key]} /* Frameworks */ = {{")
        add("\t\t\tisa = PBXFrameworksBuildPhase;")
        add("\t\t\tbuildActionMask = 2147483647;")
        add("\t\t\tfiles = (")
        add("\t\t\t);")
        add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        add("\t\t};")
    add("/* End PBXFrameworksBuildPhase section */")
    add("")

    # --- PBXGroup ------------------------------------------------------------
    add("/* Begin PBXGroup section */")
    add(f"\t\t{ID['rootGroup']} = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    add(f"\t\t\t\t{ID['readme']} /* README.md */,")
    add(f"\t\t\t\t{ID['configGroup']} /* Config */,")
    add(f"\t\t\t\t{ID['docsGroup']} /* Docs */,")
    add(f"\t\t\t\t{ID['syncApp']} /* {APP_NAME} */,")
    add(f"\t\t\t\t{ID['syncUnitTests']} /* {UNIT_TESTS} */,")
    add(f"\t\t\t\t{ID['syncUITests']} /* {UI_TESTS} */,")
    add(f"\t\t\t\t{ID['productsGroup']} /* Products */,")
    add("\t\t\t);")
    add('\t\t\tsourceTree = "<group>";')
    add("\t\t};")

    add(f"\t\t{ID['configGroup']} /* Config */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    for key, name in [("xcconfigShared", "Shared.xcconfig"), ("xcconfigSigning", "Signing.xcconfig"),
                      ("xcconfigDebug", "App-Debug.xcconfig"), ("xcconfigRelease", "App-Release.xcconfig"),
                      ("infoPlist", "WallField-Info.plist")]:
        add(f"\t\t\t\t{ID[key]} /* {name} */,")
    add("\t\t\t);")
    add("\t\t\tpath = Config;")
    add('\t\t\tsourceTree = "<group>";')
    add("\t\t};")

    add(f"\t\t{ID['docsGroup']} /* Docs */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    for doc in DOC_FILES:
        add(f"\t\t\t\t{ID['doc::' + doc]} /* {doc} */,")
    add("\t\t\t);")
    add("\t\t\tpath = Docs;")
    add('\t\t\tsourceTree = "<group>";')
    add("\t\t};")

    add(f"\t\t{ID['productsGroup']} /* Products */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    add(f"\t\t\t\t{ID['appProduct']} /* {APP_NAME}.app */,")
    add(f"\t\t\t\t{ID['unitTestProduct']} /* {UNIT_TESTS}.xctest */,")
    add(f"\t\t\t\t{ID['uiTestProduct']} /* {UI_TESTS}.xctest */,")
    add("\t\t\t);")
    add("\t\t\tname = Products;")
    add('\t\t\tsourceTree = "<group>";')
    add("\t\t};")
    add("/* End PBXGroup section */")
    add("")

    # --- PBXNativeTarget -----------------------------------------------------
    add("/* Begin PBXNativeTarget section */")
    targets = [
        (ID["appTarget"], APP_NAME, ID["appConfigList"], ID["appSources"], ID["appFrameworks"],
         ID["appResources"], ID["syncApp"], ID["appProduct"], APP_NAME + ".app",
         "com.apple.product-type.application", []),
        (ID["unitTestTarget"], UNIT_TESTS, ID["unitConfigList"], ID["unitSources"], ID["unitFrameworks"],
         ID["unitResources"], ID["syncUnitTests"], ID["unitTestProduct"], UNIT_TESTS + ".xctest",
         "com.apple.product-type.bundle.unit-test", [(ID["unitDependency"], APP_NAME)]),
        (ID["uiTestTarget"], UI_TESTS, ID["uiConfigList"], ID["uiSources"], ID["uiFrameworks"],
         ID["uiResources"], ID["syncUITests"], ID["uiTestProduct"], UI_TESTS + ".xctest",
         "com.apple.product-type.bundle.ui-testing", [(ID["uiDependency"], APP_NAME)]),
    ]
    for (tid, name, cfg, src, fw, res, sync, prod, prod_name, ptype, deps) in targets:
        add(f"\t\t{tid} /* {name} */ = {{")
        add("\t\t\tisa = PBXNativeTarget;")
        add(f"\t\t\tbuildConfigurationList = {cfg} /* Build configuration list for PBXNativeTarget \"{name}\" */;")
        add("\t\t\tbuildPhases = (")
        add(f"\t\t\t\t{src} /* Sources */,")
        add(f"\t\t\t\t{fw} /* Frameworks */,")
        add(f"\t\t\t\t{res} /* Resources */,")
        add("\t\t\t);")
        add("\t\t\tbuildRules = (")
        add("\t\t\t);")
        add("\t\t\tdependencies = (")
        for dep_id, dep_name in deps:
            add(f"\t\t\t\t{dep_id} /* PBXTargetDependency {dep_name} */,")
        add("\t\t\t);")
        add("\t\t\tfileSystemSynchronizedGroups = (")
        add(f"\t\t\t\t{sync} /* {name} */,")
        add("\t\t\t);")
        add(f"\t\t\tname = {name};")
        add(f"\t\t\tproductName = {name};")
        add(f'\t\t\tproductReference = {prod} /* {prod_name} */;')
        add(f'\t\t\tproductType = "{ptype}";')
        add("\t\t};")
    add("/* End PBXNativeTarget section */")
    add("")

    # --- PBXProject ----------------------------------------------------------
    add("/* Begin PBXProject section */")
    add(f"\t\t{ID['project']} /* Project object */ = {{")
    add("\t\t\tisa = PBXProject;")
    add("\t\t\tattributes = {")
    add("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    add("\t\t\t\tLastSwiftUpdateCheck = 1600;")
    add("\t\t\t\tLastUpgradeCheck = 1600;")
    add(f'\t\t\t\tORGANIZATIONNAME = "{ORGANIZATION}";')
    add("\t\t\t\tTargetAttributes = {")
    add(f"\t\t\t\t\t{ID['appTarget']} = {{")
    add("\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;")
    add("\t\t\t\t\t};")
    add(f"\t\t\t\t\t{ID['unitTestTarget']} = {{")
    add("\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;")
    add(f"\t\t\t\t\t\tTestTargetID = {ID['appTarget']};")
    add("\t\t\t\t\t};")
    add(f"\t\t\t\t\t{ID['uiTestTarget']} = {{")
    add("\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;")
    add(f"\t\t\t\t\t\tTestTargetID = {ID['appTarget']};")
    add("\t\t\t\t\t};")
    add("\t\t\t\t};")
    add("\t\t\t};")
    add(f"\t\t\tbuildConfigurationList = {ID['projectConfigList']} /* Build configuration list for PBXProject \"{APP_NAME}\" */;")
    add('\t\t\tcompatibilityVersion = "Xcode 15.0";')
    add("\t\t\tdevelopmentRegion = en;")
    add("\t\t\thasScannedForEncodings = 0;")
    add("\t\t\tknownRegions = (")
    add("\t\t\t\ten,")
    add("\t\t\t\tBase,")
    add("\t\t\t);")
    add(f"\t\t\tmainGroup = {ID['rootGroup']};")
    add(f"\t\t\tminimizedProjectReferenceProxies = 1;")
    add(f"\t\t\tpreferredProjectObjectVersion = {OBJECT_VERSION};")
    add(f"\t\t\tproductRefGroup = {ID['productsGroup']} /* Products */;")
    add('\t\t\tprojectDirPath = "";')
    add('\t\t\tprojectRoot = "";')
    add("\t\t\ttargets = (")
    add(f"\t\t\t\t{ID['appTarget']} /* {APP_NAME} */,")
    add(f"\t\t\t\t{ID['unitTestTarget']} /* {UNIT_TESTS} */,")
    add(f"\t\t\t\t{ID['uiTestTarget']} /* {UI_TESTS} */,")
    add("\t\t\t);")
    add("\t\t};")
    add("/* End PBXProject section */")
    add("")

    # --- PBXResourcesBuildPhase ---------------------------------------------
    add("/* Begin PBXResourcesBuildPhase section */")
    for key in ["appResources", "unitResources", "uiResources"]:
        add(f"\t\t{ID[key]} /* Resources */ = {{")
        add("\t\t\tisa = PBXResourcesBuildPhase;")
        add("\t\t\tbuildActionMask = 2147483647;")
        add("\t\t\tfiles = (")
        add("\t\t\t);")
        add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        add("\t\t};")
    add("/* End PBXResourcesBuildPhase section */")
    add("")

    # --- PBXSourcesBuildPhase ------------------------------------------------
    add("/* Begin PBXSourcesBuildPhase section */")
    for key in ["appSources", "unitSources", "uiSources"]:
        add(f"\t\t{ID[key]} /* Sources */ = {{")
        add("\t\t\tisa = PBXSourcesBuildPhase;")
        add("\t\t\tbuildActionMask = 2147483647;")
        add("\t\t\tfiles = (")
        add("\t\t\t);")
        add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        add("\t\t};")
    add("/* End PBXSourcesBuildPhase section */")
    add("")

    # --- PBXTargetDependency / PBXContainerItemProxy -------------------------
    add("/* Begin PBXContainerItemProxy section */")
    for proxy_key in ["unitProxy", "uiProxy"]:
        add(f"\t\t{ID[proxy_key]} /* PBXContainerItemProxy */ = {{")
        add("\t\t\tisa = PBXContainerItemProxy;")
        add(f"\t\t\tcontainerPortal = {ID['project']} /* Project object */;")
        add("\t\t\tproxyType = 1;")
        add(f"\t\t\tremoteGlobalIDString = {ID['appTarget']};")
        add(f"\t\t\tremoteInfo = {APP_NAME};")
        add("\t\t};")
    add("/* End PBXContainerItemProxy section */")
    add("")

    add("/* Begin PBXTargetDependency section */")
    for dep_key, proxy_key in [("unitDependency", "unitProxy"), ("uiDependency", "uiProxy")]:
        add(f"\t\t{ID[dep_key]} /* PBXTargetDependency */ = {{")
        add("\t\t\tisa = PBXTargetDependency;")
        add(f"\t\t\ttarget = {ID['appTarget']} /* {APP_NAME} */;")
        add(f"\t\t\ttargetProxy = {ID[proxy_key]} /* PBXContainerItemProxy */;")
        add("\t\t};")
    add("/* End PBXTargetDependency section */")
    add("")

    # --- XCBuildConfiguration ------------------------------------------------
    add("/* Begin XCBuildConfiguration section */")
    configs = [
        (ID["projectDebug"], "Debug", ID["xcconfigDebug"], "App-Debug.xcconfig", {}),
        (ID["projectRelease"], "Release", ID["xcconfigRelease"], "App-Release.xcconfig", {}),
        (ID["appDebug"], "Debug", None, None, APP_SETTINGS),
        (ID["appRelease"], "Release", None, None, APP_SETTINGS),
        (ID["unitDebug"], "Debug", None, None, UNIT_SETTINGS),
        (ID["unitRelease"], "Release", None, None, UNIT_SETTINGS),
        (ID["uiDebug"], "Debug", None, None, UI_SETTINGS),
        (ID["uiRelease"], "Release", None, None, UI_SETTINGS),
    ]
    for cid, cname, base_ref, base_name, extra in configs:
        add(f"\t\t{cid} /* {cname} */ = {{")
        add("\t\t\tisa = XCBuildConfiguration;")
        if base_ref:
            add(f"\t\t\tbaseConfigurationReference = {base_ref} /* {base_name} */;")
        add("\t\t\tbuildSettings = {")
        if extra:
            add(settings_block(extra, "\t\t\t\t"))
        add("\t\t\t};")
        add(f"\t\t\tname = {cname};")
        add("\t\t};")
    add("/* End XCBuildConfiguration section */")
    add("")

    # --- XCConfigurationList -------------------------------------------------
    add("/* Begin XCConfigurationList section */")
    lists = [
        (ID["projectConfigList"], f'PBXProject "{APP_NAME}"', ID["projectDebug"], ID["projectRelease"]),
        (ID["appConfigList"], f'PBXNativeTarget "{APP_NAME}"', ID["appDebug"], ID["appRelease"]),
        (ID["unitConfigList"], f'PBXNativeTarget "{UNIT_TESTS}"', ID["unitDebug"], ID["unitRelease"]),
        (ID["uiConfigList"], f'PBXNativeTarget "{UI_TESTS}"', ID["uiDebug"], ID["uiRelease"]),
    ]
    for lid, label, debug_id, release_id in lists:
        add(f"\t\t{lid} /* Build configuration list for {label} */ = {{")
        add("\t\t\tisa = XCConfigurationList;")
        add("\t\t\tbuildConfigurations = (")
        add(f"\t\t\t\t{debug_id} /* Debug */,")
        add(f"\t\t\t\t{release_id} /* Release */,")
        add("\t\t\t);")
        add("\t\t\tdefaultConfigurationIsVisible = 0;")
        add("\t\t\tdefaultConfigurationName = Release;")
        add("\t\t};")
    add("/* End XCConfigurationList section */")
    add("")

    add("\t};")
    add(f"\trootObject = {ID['project']} /* Project object */;")
    add("}")
    return "\n".join(L) + "\n"


SCHEME_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{app_id}"
               BuildableName = "WallField.app"
               BlueprintName = "WallField"
               ReferencedContainer = "container:WallField.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <!-- Deliberately no TestPlans element. Its mere presence, even when
           empty, puts the scheme into test-plan mode, and xcodebuild then
           refuses to test: "the scheme uses test plans but has no test plan(s)
           associated with it". The test bundles are listed directly below. -->
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{unit_id}"
               BuildableName = "WallFieldTests.xctest"
               BlueprintName = "WallFieldTests"
               ReferencedContainer = "container:WallField.xcodeproj">
            </BuildableReference>
         </TestableReference>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{ui_id}"
               BuildableName = "WallFieldUITests.xctest"
               BlueprintName = "WallFieldUITests"
               ReferencedContainer = "container:WallField.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "NO">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_id}"
            BuildableName = "WallField.app"
            BlueprintName = "WallField"
            ReferencedContainer = "container:WallField.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
{launch_arguments}   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_id}"
            BuildableName = "WallField.app"
            BlueprintName = "WallField"
            ReferencedContainer = "container:WallField.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""

DEMO_ARGUMENTS = """      <CommandLineArguments>
         <CommandLineArgument
            argument = "-WallFieldDemoMode"
            isEnabled = "YES">
         </CommandLineArgument>
      </CommandLineArguments>
"""


def main() -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    proj_dir = os.path.join(root, "WallField.xcodeproj")
    schemes_dir = os.path.join(proj_dir, "xcshareddata", "xcschemes")
    workspace_dir = os.path.join(proj_dir, "project.xcworkspace")
    os.makedirs(schemes_dir, exist_ok=True)
    os.makedirs(os.path.join(workspace_dir, "xcshareddata"), exist_ok=True)

    with open(os.path.join(proj_dir, "project.pbxproj"), "w", encoding="utf-8") as handle:
        handle.write(build_pbxproj())

    scheme_args = {"app_id": ID["appTarget"], "unit_id": ID["unitTestTarget"], "ui_id": ID["uiTestTarget"]}
    with open(os.path.join(schemes_dir, "WallField.xcscheme"), "w", encoding="utf-8") as handle:
        handle.write(SCHEME_TEMPLATE.format(launch_arguments="", **scheme_args))
    with open(os.path.join(schemes_dir, "WallField (Simulated Data).xcscheme"), "w", encoding="utf-8") as handle:
        handle.write(SCHEME_TEMPLATE.format(launch_arguments=DEMO_ARGUMENTS, **scheme_args))

    with open(os.path.join(workspace_dir, "contents.xcworkspacedata"), "w", encoding="utf-8") as handle:
        handle.write(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<Workspace\n'
            '   version = "1.0">\n'
            '   <FileRef\n'
            '      location = "self:">\n'
            '   </FileRef>\n'
            '</Workspace>\n'
        )
    with open(os.path.join(workspace_dir, "xcshareddata", "WorkspaceSettings.xcsettings"), "w", encoding="utf-8") as handle:
        handle.write(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0">\n'
            '<dict>\n'
            '\t<key>BuildSystemType</key>\n'
            '\t<string>Latest</string>\n'
            '</dict>\n'
            '</plist>\n'
        )

    print("Generated WallField.xcodeproj (objectVersion %d)" % OBJECT_VERSION)
    return 0


if __name__ == "__main__":
    sys.exit(main())
