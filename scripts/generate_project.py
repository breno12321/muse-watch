"""Generate the dependency-free Xcode project; keep signing overrides local."""
from pathlib import Path
import hashlib, re
root = Path(__file__).resolve().parent.parent
project_path = root / 'MuseWatch.xcodeproj/project.pbxproj'
old = project_path.read_text() if project_path.exists() else ''
match = re.search(r'DEVELOPMENT_TEAM = ([A-Za-z0-9]+);', old)
local_signing = root / 'Configuration/Local.xcconfig'
if match and not local_signing.exists():
    local_signing.parent.mkdir(parents=True, exist_ok=True)
    local_signing.write_text(f'DEVELOPMENT_TEAM = {match.group(1)}\n')
    local_signing.chmod(0o600)
uid = lambda value: hashlib.sha1(value.encode()).hexdigest()[:24].upper()
objects = []
def obj(key, contents):
    objects.append(f'{uid(key)} = {{ {contents} }};')
    return uid(key)
def array(values): return '(' + ','.join(values) + ')'
products, groups, targets = [], [], []
shared = sorted((root / 'Shared').glob('*.swift'))
specs = [
    ('MuseWatch', 'watchos', 'watchos watchsimulator', '4', 'WATCHOS_DEPLOYMENT_TARGET = 10.0;', 'dev.breno.musewatch.phone.watchkitapp'),
    ('MusePhone', 'iphoneos', 'iphoneos iphonesimulator', '1', 'IPHONEOS_DEPLOYMENT_TARGET = 17.0;', 'dev.breno.musewatch.phone'),
    ('MuseSetup', 'macosx', 'macosx', '', 'MACOSX_DEPLOYMENT_TARGET = 14.0;', 'dev.breno.musewatch.setup'),
]
shared_refs = []
for path in shared:
    rel = str(path.relative_to(root))
    shared_refs.append(obj(rel, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path.name}"; sourceTree = "<group>";'))
groups.append(obj('Shared-group', f'isa = PBXGroup; children = {array(shared_refs)}; path = Shared; sourceTree = "<group>";'))
signing_ref = obj('local-signing-base', 'isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Signing.xcconfig; sourceTree = "<group>";')
groups.append(obj('Configuration-group', f'isa = PBXGroup; children = ({signing_ref}); path = Configuration; sourceTree = "<group>";'))
for name, sdk, platforms, family, deployment, bundle in specs:
    source_files = sorted((root / name).glob('*.swift'))
    refs, builds, resources = [], [], []
    for path in source_files:
        rel = str(path.relative_to(root))
        ref = obj(rel, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path.name}"; sourceTree = "<group>";')
        refs.append(ref); builds.append(obj(name+'-build-'+rel, f'isa = PBXBuildFile; fileRef = {ref};'))
    if True:
        for path, ref in zip(shared, shared_refs):
            if name == 'MuseWatch' and path.name not in ['RelayModels.swift', 'RelayConnectivity.swift', 'ReplyAudio.swift', 'MuseRichText.swift', 'MuseMarkdown.swift']: continue
            builds.append(obj(name+'-build-'+str(path.relative_to(root)), f'isa = PBXBuildFile; fileRef = {ref};'))
    if name in ['MuseWatch', 'MusePhone']:
        asset = obj(name+'-assets', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";')
        refs.append(asset); resources.append(obj(name+'-assetbuild', f'isa = PBXBuildFile; fileRef = {asset};'))
    info = obj(name+'-info', 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";')
    refs.append(info)
    groups.append(obj(name+'-group', f'isa = PBXGroup; children = {array(refs)}; path = {name}; sourceTree = "<group>";'))
    product = obj(name+'-product', f'isa = PBXFileReference; explicitFileType = wrapper.application; path = {name}.app; sourceTree = BUILT_PRODUCTS_DIR;')
    products.append(product)
    phases = [obj(name+'-sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {array(builds)}; runOnlyForDeploymentPostprocessing = 0;'), obj(name+'-frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;'), obj(name+'-resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {array(resources)}; runOnlyForDeploymentPostprocessing = 0;')]
    dependencies = []
    if name == 'MusePhone':
        embedded = obj('embed-watch-build', f'isa = PBXBuildFile; fileRef = {uid("MuseWatch-product")}; settings = {{ ATTRIBUTES = (RemoveHeadersOnCopy); }};')
        phases.append(obj('embed-watch-phase', f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = "$(CONTENTS_FOLDER_PATH)/Watch"; dstSubfolderSpec = 16; files = ({embedded}); name = "Embed Watch Content"; runOnlyForDeploymentPostprocessing = 0;'))
        proxy = obj('watch-proxy', f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("target")}; remoteInfo = MuseWatch;')
        dependencies.append(obj('watch-dependency', f'isa = PBXTargetDependency; target = {uid("target")}; targetProxy = {proxy};'))
    configs = []
    for config in ['Debug', 'Release']:
        optimization = '-Onone' if config == 'Debug' else '-O'
        conditions = 'DEBUG' if config == 'Debug' else ''
        extra = 'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;' if name in ['MuseWatch', 'MusePhone'] else ''
        if name == 'MusePhone': extra += 'SUPPORTS_MACCATALYST = NO;'
        if name == 'MuseWatch': extra += 'SKIP_INSTALL = YES;'
        if name == 'MuseSetup': extra += 'ENABLE_APP_SANDBOX = NO; COMBINE_HIDPI_IMAGES = YES;'
        settings = f'''SDKROOT = {sdk}; SUPPORTED_PLATFORMS = "{platforms}"; {deployment}
            PRODUCT_BUNDLE_IDENTIFIER = {bundle}; PRODUCT_NAME = "$(TARGET_NAME)";
            INFOPLIST_FILE = {name}/Info.plist; GENERATE_INFOPLIST_FILE = NO;
            SWIFT_VERSION = 5.0; SWIFT_STRICT_CONCURRENCY = complete;
            SWIFT_ACTIVE_COMPILATION_CONDITIONS = "{conditions}"; SWIFT_OPTIMIZATION_LEVEL = "{optimization}";
            CODE_SIGN_STYLE = Automatic; {extra}'''
        if family: settings += f' TARGETED_DEVICE_FAMILY = "{family}";'
        configs.append(obj(name+config, f'isa = XCBuildConfiguration; name = {config}; baseConfigurationReference = {signing_ref}; buildSettings = {{ {settings} }};'))
    config_list = obj(name+'-configs', f'isa = XCConfigurationList; buildConfigurations = {array(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    target = obj('target' if name == 'MuseWatch' else name+'-target', f'isa = PBXNativeTarget; buildConfigurationList = {config_list}; buildPhases = {array(phases)}; buildRules = (); dependencies = {array(dependencies)}; name = {name}; productName = {name}; productReference = {product}; productType = "com.apple.product-type.application";')
    targets.append(target)
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:MuseWatch.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:MuseWatch.xcodeproj"/></BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>'''
    (root / f'MuseWatch.xcodeproj/xcshareddata/xcschemes/{name}.xcscheme').write_text(scheme)
pconfigs = [obj('project'+name, f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ CLANG_ENABLE_MODULES = YES; }};') for name in ['Debug','Release']]
pconfig = obj('project-configs', f'isa = XCConfigurationList; buildConfigurations = {array(pconfigs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
products_group = obj('products', f'isa = PBXGroup; children = {array(products)}; name = Products; sourceTree = "<group>";')
main = obj('main', f'isa = PBXGroup; children = {array(groups+[products_group])}; sourceTree = "<group>";')
project = obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2700; }}; buildConfigurationList = {pconfig}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,Base); mainGroup = {main}; productRefGroup = {products_group}; projectDirPath = ""; projectRoot = ""; targets = {array(targets)};')
project_path.write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {project}; }}\n')
