
#import "MBEViewController.h"
#import "MBEMesh.h"
#import "MBEMeshletRenderer.h"

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>

typedef struct MBEMeshletCompositionPreset {
    NSUInteger maxVertexCount;
    NSUInteger maxTriangleCount;
    __unsafe_unretained NSString *label;
} MBEMeshletCompositionPreset;

static const MBEMeshletCompositionPreset kMeshletCompositionPresets[] = {
    { 64, 64, @"64 / 64" },
    { 64, 126, @"64 / 126" },
    { 64, 128, @"64 / 128" },
    { 128, 128, @"128 / 128" },
    { 128, 256, @"128 / 256" },
    { 256, 256, @"256 / 256" },
    { 256, 512, @"256 / 512" },
};
static const NSUInteger kMeshletCompositionPresetCount = sizeof(kMeshletCompositionPresets) / sizeof(kMeshletCompositionPresets[0]);
static const NSUInteger kDefaultMeshletCompositionPresetIndex = 4;

@interface MBEBenchmarkCase : NSObject
@property (nonatomic, assign) MBERenderPath renderPath;
@property (nonatomic, assign) MBEMeshletCullingMode meshletCullingMode;
@property (nonatomic, assign) MBEVSPSCullingMode vspsCullingMode;
@property (nonatomic, assign) MBEMeshOptimizationOptions optimizationOptions;
@property (nonatomic, copy) NSString *optimizationName;
@property (nonatomic, copy) NSString *name;
+ (instancetype)caseWithName:(NSString *)name
                  renderPath:(MBERenderPath)renderPath
          meshletCullingMode:(MBEMeshletCullingMode)meshletCullingMode
             vspsCullingMode:(MBEVSPSCullingMode)vspsCullingMode
             optimizationName:(NSString *)optimizationName
          optimizationOptions:(MBEMeshOptimizationOptions)optimizationOptions;
@end

@implementation MBEBenchmarkCase

+ (instancetype)caseWithName:(NSString *)name
                  renderPath:(MBERenderPath)renderPath
          meshletCullingMode:(MBEMeshletCullingMode)meshletCullingMode
             vspsCullingMode:(MBEVSPSCullingMode)vspsCullingMode
            optimizationName:(NSString *)optimizationName
         optimizationOptions:(MBEMeshOptimizationOptions)optimizationOptions {
    MBEBenchmarkCase *benchmarkCase = [MBEBenchmarkCase new];
    benchmarkCase.name = name;
    benchmarkCase.renderPath = renderPath;
    benchmarkCase.meshletCullingMode = meshletCullingMode;
    benchmarkCase.vspsCullingMode = vspsCullingMode;
    benchmarkCase.optimizationName = optimizationName;
    benchmarkCase.optimizationOptions = optimizationOptions;
    return benchmarkCase;
}

@end

static BOOL MBEEnvironmentFlagEnabled(NSString *value) {
    if (value.length == 0) {
        return NO;
    }
    NSString *lowercaseValue = value.lowercaseString;
    return [lowercaseValue isEqualToString:@"1"] ||
        [lowercaseValue isEqualToString:@"yes"] ||
        [lowercaseValue isEqualToString:@"true"] ||
        [lowercaseValue isEqualToString:@"on"];
}

static NSUInteger MBEEnvironmentUnsignedValue(NSString *value, NSUInteger fallbackValue) {
    if (value.length == 0) {
        return fallbackValue;
    }
    long long parsedValue = value.longLongValue;
    return parsedValue > 0 ? (NSUInteger)parsedValue : fallbackValue;
}

static NSString *MBEOptimizationOptionsCSVName(MBEMeshOptimizationOptions options) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (options & MBEMeshOptimizationOptionRemap) {
        [names addObject:@"remap"];
    }
    if (options & MBEMeshOptimizationOptionVertexCache) {
        [names addObject:@"vertex_cache"];
    }
    if (options & MBEMeshOptimizationOptionOverdraw) {
        [names addObject:@"overdraw"];
    }
    if (options & MBEMeshOptimizationOptionVertexFetch) {
        [names addObject:@"vertex_fetch"];
    }
    if (options & MBEMeshOptimizationOptionMeshlets) {
        [names addObject:@"meshlets"];
    }
    if (options & MBEMeshOptimizationOptionOptimizeMeshlet) {
        [names addObject:@"optimize_meshlet"];
    }
    return names.count > 0 ? [names componentsJoinedByString:@"|"] : @"raw";
}

@interface MBEViewController () <MTKViewDelegate>
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) MBEMeshletRenderer *renderer;
@property (nonatomic, weak) MTKView *mtkView;
@property (nonatomic, strong) NSURL *assetURL;
@property (nonatomic, strong) NSTextField *statsLabel;
@property (nonatomic, strong) NSSegmentedControl *renderPathControl;
@property (nonatomic, strong) NSView *meshletCullingBackground;
@property (nonatomic, strong) NSSegmentedControl *meshletCullingControl;
@property (nonatomic, strong) NSView *vspsCullingBackground;
@property (nonatomic, strong) NSSegmentedControl *vspsCullingControl;
@property (nonatomic, strong) NSView *optimizationBackground;
@property (nonatomic, strong) NSButton *remapControl;
@property (nonatomic, strong) NSButton *vertexCacheControl;
@property (nonatomic, strong) NSButton *overdrawControl;
@property (nonatomic, strong) NSButton *vertexFetchControl;
@property (nonatomic, strong) NSButton *meshletsControl;
@property (nonatomic, strong) NSButton *optimizeMeshletControl;
@property (nonatomic, strong) NSView *meshletCompositionBackground;
@property (nonatomic, strong) NSPopUpButton *meshletCompositionPopup;
@property (nonatomic, strong) NSArray<NSControl *> *rebuildControls;
@property (nonatomic, assign) MBEMeshOptimizationOptions selectedOptimizationOptions;
@property (nonatomic, assign) MBEMeshOptimizationOptions currentEffectiveOptimizationOptions;
@property (nonatomic, assign) NSUInteger selectedMeshletCompositionPresetIndex;
@property (nonatomic, strong) id<MTLCommandBuffer> lastSubmittedCommandBuffer;
@property (nonatomic, assign) BOOL isRebuildingMesh;
@property (nonatomic, assign) NSUInteger statsFrameCount;
@property (nonatomic, assign) CFTimeInterval statsWindowStartTime;
@property (nonatomic, assign) double currentFPS;
@property (nonatomic, assign) double latestCPUFrameMS;
@property (nonatomic, assign) double latestGPUFrameMS;
@property (nonatomic, assign) BOOL benchmarkMode;
@property (nonatomic, copy) NSArray<MBEBenchmarkCase *> *benchmarkCases;
@property (nonatomic, strong) NSMutableArray<NSString *> *benchmarkRows;
@property (nonatomic, copy) NSString *benchmarkOutputPath;
@property (nonatomic, assign) NSUInteger benchmarkWarmupFrames;
@property (nonatomic, assign) NSUInteger benchmarkSampleFrames;
@property (nonatomic, assign) NSUInteger benchmarkCaseIndex;
@property (nonatomic, assign) NSUInteger benchmarkSubmittedFrames;
@property (nonatomic, assign) NSUInteger benchmarkCompletedSamples;

- (NSButton *)newOptimizationCheckboxWithTitle:(NSString *)title;
- (MBEMeshOptimizationOptions)effectiveOptimizationOptionsForRenderPath:(MBERenderPath)renderPath;
- (MBEMesh *)newMeshWithOptimizationOptions:(MBEMeshOptimizationOptions)optimizationOptions;
- (void)configureBenchmarkIfRequested;
- (NSArray<MBEBenchmarkCase *> *)makeBenchmarkCases;
- (void)beginBenchmarkCaseAtIndex:(NSUInteger)caseIndex;
- (void)appendBenchmarkSampleForCase:(MBEBenchmarkCase *)benchmarkCase
                           caseIndex:(NSUInteger)caseIndex
                         sampleIndex:(NSUInteger)sampleIndex
                            cpuFrame:(double)cpuFrameMS
                            gpuFrame:(double)gpuFrameMS
                     visibleInstances:(NSString *)visibleInstances
                           resolution:(CGSize)resolution;
- (void)finishBenchmark;
@end

@implementation MBEViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.device = MTLCreateSystemDefaultDevice();
    self.commandQueue = [self.device newCommandQueue];
    self.assetURL = [[NSBundle mainBundle] URLForResource:@"kitten" withExtension:@"obj"];
    self.selectedOptimizationOptions = MBEMeshOptimizationOptionMeshlets | MBEMeshOptimizationOptionOptimizeMeshlet;
    self.selectedMeshletCompositionPresetIndex = kDefaultMeshletCompositionPresetIndex;

    MTKView *mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:self.device];
    mtkView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.view addSubview:mtkView];

    self.mtkView = mtkView;
    self.mtkView.delegate = self;
    self.mtkView.sampleCount = 1;
    self.mtkView.clearColor = MTLClearColorMake(1, 1, 1, 1.0);
    self.mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    self.mtkView.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    self.mtkView.depthStencilAttachmentTextureUsage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;

    [self makeStatsOverlay];

    self.renderer = [[MBEMeshletRenderer alloc] initWithDevice:self.device
                                                  commandQueue:self.commandQueue
                                                          view:self.mtkView];

    self.currentEffectiveOptimizationOptions = [self effectiveOptimizationOptionsForRenderPath:self.renderer.renderPath];
    self.renderer.mesh = [self newMeshWithOptimizationOptions:self.currentEffectiveOptimizationOptions];
    [self updateMeshletCullingControlVisibility];
    [self updateOptimizationControlStateForRenderPath:self.renderer.renderPath];
    [self configureBenchmarkIfRequested];
}

- (void)makeStatsOverlay {
    NSTextField *statsLabel = [NSTextField labelWithString:@"Mode: Meshlet\nCull: Full\nFPS: --\nCPU: -- ms\nGPU: -- ms\nInst: --/--"];
    statsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    statsLabel.font = [NSFont monospacedDigitSystemFontOfSize:12.0 weight:NSFontWeightMedium];
    statsLabel.textColor = NSColor.whiteColor;
    statsLabel.maximumNumberOfLines = 6;
    statsLabel.alignment = NSTextAlignmentLeft;
    statsLabel.wantsLayer = YES;
    statsLabel.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.65].CGColor;
    statsLabel.layer.cornerRadius = 6.0;

    NSSegmentedControl *renderPathControl = [NSSegmentedControl segmentedControlWithLabels:@[ @"Indexed", @"Pulling", @"Meshlet" ]
                                                                             trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                                   target:self
                                                                                   action:@selector(renderPathControlChanged:)];
    renderPathControl.translatesAutoresizingMaskIntoConstraints = NO;
    renderPathControl.selectedSegment = MBERenderPathMeshlet;
    renderPathControl.controlSize = NSControlSizeRegular;
    renderPathControl.segmentStyle = NSSegmentStyleSeparated;
    renderPathControl.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    for (NSInteger segment = 0; segment < renderPathControl.segmentCount; ++segment) {
        [renderPathControl setWidth:72.0 forSegment:segment];
    }

    NSView *renderPathBackground = [NSView new];
    renderPathBackground.translatesAutoresizingMaskIntoConstraints = NO;
    renderPathBackground.wantsLayer = YES;
    renderPathBackground.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.65].CGColor;
    renderPathBackground.layer.cornerRadius = 6.0;

    NSSegmentedControl *meshletCullingControl = [NSSegmentedControl segmentedControlWithLabels:@[ @"No Cull", @"Frustum", @"Full", @"Full+HiZ" ]
                                                                                  trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                                        target:self
                                                                                        action:@selector(meshletCullingControlChanged:)];
    meshletCullingControl.translatesAutoresizingMaskIntoConstraints = NO;
    meshletCullingControl.selectedSegment = MBEMeshletCullingModeFull;
    meshletCullingControl.controlSize = NSControlSizeRegular;
    meshletCullingControl.segmentStyle = NSSegmentStyleSeparated;
    meshletCullingControl.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    for (NSInteger segment = 0; segment < meshletCullingControl.segmentCount; ++segment) {
        [meshletCullingControl setWidth:80.0 forSegment:segment];
    }

    NSView *meshletCullingBackground = [NSView new];
    meshletCullingBackground.translatesAutoresizingMaskIntoConstraints = NO;
    meshletCullingBackground.wantsLayer = YES;
    meshletCullingBackground.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.65].CGColor;
    meshletCullingBackground.layer.cornerRadius = 6.0;

    NSSegmentedControl *vspsCullingControl = [NSSegmentedControl segmentedControlWithLabels:@[ @"No Cull", @"CPU Frustum", @"GPU Frustum", @"GPU HiZ" ]
                                                                                trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                                      target:self
                                                                                      action:@selector(vspsCullingControlChanged:)];
    vspsCullingControl.translatesAutoresizingMaskIntoConstraints = NO;
    vspsCullingControl.selectedSegment = MBEVSPSCullingModeCPUFrustum;
    vspsCullingControl.controlSize = NSControlSizeRegular;
    vspsCullingControl.segmentStyle = NSSegmentStyleSeparated;
    vspsCullingControl.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    for (NSInteger segment = 0; segment < vspsCullingControl.segmentCount; ++segment) {
        [vspsCullingControl setWidth:96.0 forSegment:segment];
    }

    NSView *vspsCullingBackground = [NSView new];
    vspsCullingBackground.translatesAutoresizingMaskIntoConstraints = NO;
    vspsCullingBackground.wantsLayer = YES;
    vspsCullingBackground.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.65].CGColor;
    vspsCullingBackground.layer.cornerRadius = 6.0;

    NSButton *remapControl = [self newOptimizationCheckboxWithTitle:@"Remap"];
    NSButton *vertexCacheControl = [self newOptimizationCheckboxWithTitle:@"Vertex Cache"];
    NSButton *overdrawControl = [self newOptimizationCheckboxWithTitle:@"Overdraw"];
    NSButton *vertexFetchControl = [self newOptimizationCheckboxWithTitle:@"Vertex Fetch"];
    NSButton *meshletsControl = [self newOptimizationCheckboxWithTitle:@"Meshlets"];
    NSButton *optimizeMeshletControl = [self newOptimizationCheckboxWithTitle:@"Optimize Meshlet"];

    NSView *optimizationBackground = [NSView new];
    optimizationBackground.translatesAutoresizingMaskIntoConstraints = NO;
    optimizationBackground.wantsLayer = YES;
    optimizationBackground.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.65].CGColor;
    optimizationBackground.layer.cornerRadius = 6.0;

    NSTextField *meshletCompositionTitle = [NSTextField labelWithString:@"Meshlet Composition"];
    meshletCompositionTitle.translatesAutoresizingMaskIntoConstraints = NO;
    meshletCompositionTitle.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    meshletCompositionTitle.textColor = NSColor.whiteColor;
    meshletCompositionTitle.alignment = NSTextAlignmentLeft;

    NSPopUpButton *meshletCompositionPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    meshletCompositionPopup.translatesAutoresizingMaskIntoConstraints = NO;
    meshletCompositionPopup.target = self;
    meshletCompositionPopup.action = @selector(meshletCompositionControlChanged:);
    meshletCompositionPopup.controlSize = NSControlSizeRegular;
    meshletCompositionPopup.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    for (NSUInteger i = 0; i < kMeshletCompositionPresetCount; ++i) {
        [meshletCompositionPopup addItemWithTitle:kMeshletCompositionPresets[i].label];
    }
    [meshletCompositionPopup selectItemAtIndex:self.selectedMeshletCompositionPresetIndex];

    NSView *meshletCompositionBackground = [NSView new];
    meshletCompositionBackground.translatesAutoresizingMaskIntoConstraints = NO;
    meshletCompositionBackground.wantsLayer = YES;
    meshletCompositionBackground.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.65].CGColor;
    meshletCompositionBackground.layer.cornerRadius = 6.0;

    [self.view addSubview:statsLabel];
    [self.view addSubview:renderPathBackground];
    [renderPathBackground addSubview:renderPathControl];
    [self.view addSubview:meshletCullingBackground];
    [meshletCullingBackground addSubview:meshletCullingControl];
    [self.view addSubview:vspsCullingBackground];
    [vspsCullingBackground addSubview:vspsCullingControl];
    [self.view addSubview:optimizationBackground];
    [optimizationBackground addSubview:remapControl];
    [optimizationBackground addSubview:vertexCacheControl];
    [optimizationBackground addSubview:overdrawControl];
    [optimizationBackground addSubview:vertexFetchControl];
    [optimizationBackground addSubview:meshletsControl];
    [optimizationBackground addSubview:optimizeMeshletControl];
    [self.view addSubview:meshletCompositionBackground];
    [meshletCompositionBackground addSubview:meshletCompositionTitle];
    [meshletCompositionBackground addSubview:meshletCompositionPopup];
    [NSLayoutConstraint activateConstraints:@[
        [statsLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12.0],
        [statsLabel.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:12.0],
        [statsLabel.widthAnchor constraintEqualToConstant:170.0],
        [statsLabel.heightAnchor constraintEqualToConstant:112.0],
        [renderPathBackground.leadingAnchor constraintEqualToAnchor:statsLabel.leadingAnchor],
        [renderPathBackground.topAnchor constraintEqualToAnchor:statsLabel.bottomAnchor constant:8.0],
        [renderPathBackground.widthAnchor constraintEqualToConstant:232.0],
        [renderPathBackground.heightAnchor constraintEqualToConstant:40.0],
        [renderPathControl.centerXAnchor constraintEqualToAnchor:renderPathBackground.centerXAnchor],
        [renderPathControl.centerYAnchor constraintEqualToAnchor:renderPathBackground.centerYAnchor],
        [renderPathControl.widthAnchor constraintEqualToConstant:216.0],
        [renderPathControl.heightAnchor constraintEqualToConstant:28.0],
        [meshletCullingBackground.leadingAnchor constraintEqualToAnchor:statsLabel.leadingAnchor],
        [meshletCullingBackground.topAnchor constraintEqualToAnchor:renderPathBackground.bottomAnchor constant:8.0],
        [meshletCullingBackground.widthAnchor constraintEqualToConstant:336.0],
        [meshletCullingBackground.heightAnchor constraintEqualToConstant:40.0],
        [meshletCullingControl.centerXAnchor constraintEqualToAnchor:meshletCullingBackground.centerXAnchor],
        [meshletCullingControl.centerYAnchor constraintEqualToAnchor:meshletCullingBackground.centerYAnchor],
        [meshletCullingControl.widthAnchor constraintEqualToConstant:320.0],
        [meshletCullingControl.heightAnchor constraintEqualToConstant:28.0],
        [vspsCullingBackground.leadingAnchor constraintEqualToAnchor:statsLabel.leadingAnchor],
        [vspsCullingBackground.topAnchor constraintEqualToAnchor:renderPathBackground.bottomAnchor constant:8.0],
        [vspsCullingBackground.widthAnchor constraintEqualToConstant:400.0],
        [vspsCullingBackground.heightAnchor constraintEqualToConstant:40.0],
        [vspsCullingControl.centerXAnchor constraintEqualToAnchor:vspsCullingBackground.centerXAnchor],
        [vspsCullingControl.centerYAnchor constraintEqualToAnchor:vspsCullingBackground.centerYAnchor],
        [vspsCullingControl.widthAnchor constraintEqualToConstant:384.0],
        [vspsCullingControl.heightAnchor constraintEqualToConstant:28.0],
        [optimizationBackground.leadingAnchor constraintEqualToAnchor:statsLabel.leadingAnchor],
        [optimizationBackground.topAnchor constraintEqualToAnchor:meshletCullingBackground.bottomAnchor constant:8.0],
        [optimizationBackground.widthAnchor constraintEqualToConstant:250.0],
        [optimizationBackground.heightAnchor constraintEqualToConstant:176.0],
        [remapControl.leadingAnchor constraintEqualToAnchor:optimizationBackground.leadingAnchor constant:10.0],
        [remapControl.topAnchor constraintEqualToAnchor:optimizationBackground.topAnchor constant:9.0],
        [vertexCacheControl.leadingAnchor constraintEqualToAnchor:remapControl.leadingAnchor],
        [vertexCacheControl.topAnchor constraintEqualToAnchor:remapControl.bottomAnchor constant:5.0],
        [overdrawControl.leadingAnchor constraintEqualToAnchor:remapControl.leadingAnchor],
        [overdrawControl.topAnchor constraintEqualToAnchor:vertexCacheControl.bottomAnchor constant:5.0],
        [vertexFetchControl.leadingAnchor constraintEqualToAnchor:remapControl.leadingAnchor],
        [vertexFetchControl.topAnchor constraintEqualToAnchor:overdrawControl.bottomAnchor constant:5.0],
        [meshletsControl.leadingAnchor constraintEqualToAnchor:remapControl.leadingAnchor],
        [meshletsControl.topAnchor constraintEqualToAnchor:vertexFetchControl.bottomAnchor constant:5.0],
        [optimizeMeshletControl.leadingAnchor constraintEqualToAnchor:remapControl.leadingAnchor],
        [optimizeMeshletControl.topAnchor constraintEqualToAnchor:meshletsControl.bottomAnchor constant:5.0],
        [meshletCompositionBackground.leadingAnchor constraintEqualToAnchor:statsLabel.leadingAnchor],
        [meshletCompositionBackground.topAnchor constraintEqualToAnchor:optimizationBackground.bottomAnchor constant:8.0],
        [meshletCompositionBackground.widthAnchor constraintEqualToConstant:250.0],
        [meshletCompositionBackground.heightAnchor constraintEqualToConstant:68.0],
        [meshletCompositionTitle.leadingAnchor constraintEqualToAnchor:meshletCompositionBackground.leadingAnchor constant:10.0],
        [meshletCompositionTitle.topAnchor constraintEqualToAnchor:meshletCompositionBackground.topAnchor constant:8.0],
        [meshletCompositionTitle.trailingAnchor constraintEqualToAnchor:meshletCompositionBackground.trailingAnchor constant:-10.0],
        [meshletCompositionPopup.leadingAnchor constraintEqualToAnchor:meshletCompositionBackground.leadingAnchor constant:10.0],
        [meshletCompositionPopup.trailingAnchor constraintEqualToAnchor:meshletCompositionBackground.trailingAnchor constant:-10.0],
        [meshletCompositionPopup.topAnchor constraintEqualToAnchor:meshletCompositionTitle.bottomAnchor constant:6.0],
    ]];

    self.statsLabel = statsLabel;
    self.renderPathControl = renderPathControl;
    self.meshletCullingBackground = meshletCullingBackground;
    self.meshletCullingControl = meshletCullingControl;
    self.vspsCullingBackground = vspsCullingBackground;
    self.vspsCullingControl = vspsCullingControl;
    self.optimizationBackground = optimizationBackground;
    self.remapControl = remapControl;
    self.vertexCacheControl = vertexCacheControl;
    self.overdrawControl = overdrawControl;
    self.vertexFetchControl = vertexFetchControl;
    self.meshletsControl = meshletsControl;
    self.optimizeMeshletControl = optimizeMeshletControl;
    self.meshletCompositionBackground = meshletCompositionBackground;
    self.meshletCompositionPopup = meshletCompositionPopup;
    self.rebuildControls = @[ renderPathControl, meshletCullingControl, vspsCullingControl, remapControl, vertexCacheControl, overdrawControl, vertexFetchControl, meshletsControl, optimizeMeshletControl, meshletCompositionPopup ];
    self.statsWindowStartTime = CACurrentMediaTime();
}

- (NSButton *)newOptimizationCheckboxWithTitle:(NSString *)title {
    NSButton *button = [NSButton checkboxWithTitle:title target:self action:@selector(optimizationControlChanged:)];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.controlSize = NSControlSizeRegular;
    button.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    return button;
}

- (void)renderPathControlChanged:(NSSegmentedControl *)sender {
    [self applyRenderPath:(MBERenderPath)sender.selectedSegment];
}

- (void)meshletCullingControlChanged:(NSSegmentedControl *)sender {
    self.renderer.meshletCullingMode = (MBEMeshletCullingMode)sender.selectedSegment;
    [self.renderer invalidateHiZ];
    [self resetStatsWindow];
}

- (void)vspsCullingControlChanged:(NSSegmentedControl *)sender {
    self.renderer.vspsCullingMode = (MBEVSPSCullingMode)sender.selectedSegment;
    [self.renderer invalidateHiZ];
    [self resetStatsWindow];
}

- (void)meshletCompositionControlChanged:(NSPopUpButton *)sender {
    NSUInteger selectedIndex = sender.indexOfSelectedItem;
    if (selectedIndex >= kMeshletCompositionPresetCount) {
        [sender selectItemAtIndex:self.selectedMeshletCompositionPresetIndex];
        return;
    }
    if (selectedIndex == self.selectedMeshletCompositionPresetIndex) {
        return;
    }

    self.selectedMeshletCompositionPresetIndex = selectedIndex;
    if (self.renderer.renderPath == MBERenderPathMeshlet) {
        [self rebuildMeshForRenderPath:self.renderer.renderPath
                      effectiveOptions:self.currentEffectiveOptimizationOptions];
    }
}

- (void)optimizationControlChanged:(NSButton *)sender {
    [self updateSelectedOptimizationOptionsFromControls];
    MBERenderPath renderPath = self.renderer.renderPath;
    MBEMeshOptimizationOptions effectiveOptions = [self effectiveOptimizationOptionsForRenderPath:renderPath];
    if (effectiveOptions != self.currentEffectiveOptimizationOptions) {
        [self rebuildMeshForRenderPath:renderPath effectiveOptions:effectiveOptions];
    } else {
        [self updateOptimizationControlStateForRenderPath:renderPath];
    }
}

- (void)updateMeshletCullingControlVisibility {
    BOOL meshletMode = self.renderer.renderPath == MBERenderPathMeshlet;
    self.meshletCullingBackground.hidden = !meshletMode;
    self.vspsCullingBackground.hidden = meshletMode;
    self.meshletCompositionBackground.hidden = !meshletMode;
}

- (void)applyRenderPath:(MBERenderPath)renderPath {
    if (self.isRebuildingMesh) {
        self.renderPathControl.selectedSegment = self.renderer.renderPath;
        return;
    }

    MBEMeshOptimizationOptions effectiveOptions = [self effectiveOptimizationOptionsForRenderPath:renderPath];
    if (effectiveOptions != self.currentEffectiveOptimizationOptions) {
        [self rebuildMeshForRenderPath:renderPath effectiveOptions:effectiveOptions];
        return;
    }

    MBERenderPath previousRenderPath = self.renderer.renderPath;
    self.renderer.renderPath = renderPath;
    if (previousRenderPath != renderPath) {
        [self.renderer invalidateHiZ];
    }
    [self updateMeshletCullingControlVisibility];
    [self updateOptimizationControlStateForRenderPath:renderPath];
    [self resetStatsWindow];
}

- (void)updateSelectedOptimizationOptionsFromControls {
    MBEMeshOptimizationOptions options = self.selectedOptimizationOptions;
    options = self.remapControl.state == NSControlStateValueOn ? (options | MBEMeshOptimizationOptionRemap) : (options & ~MBEMeshOptimizationOptionRemap);
    options = self.vertexCacheControl.state == NSControlStateValueOn ? (options | MBEMeshOptimizationOptionVertexCache) : (options & ~MBEMeshOptimizationOptionVertexCache);
    options = self.overdrawControl.state == NSControlStateValueOn ? (options | MBEMeshOptimizationOptionOverdraw) : (options & ~MBEMeshOptimizationOptionOverdraw);
    options = self.vertexFetchControl.state == NSControlStateValueOn ? (options | MBEMeshOptimizationOptionVertexFetch) : (options & ~MBEMeshOptimizationOptionVertexFetch);

    if (self.renderer.renderPath == MBERenderPathMeshlet) {
        options |= MBEMeshOptimizationOptionMeshlets;
        options = self.optimizeMeshletControl.state == NSControlStateValueOn ? (options | MBEMeshOptimizationOptionOptimizeMeshlet) : (options & ~MBEMeshOptimizationOptionOptimizeMeshlet);
    }

    self.selectedOptimizationOptions = options;
}

- (MBEMeshOptimizationOptions)effectiveOptimizationOptionsForRenderPath:(MBERenderPath)renderPath {
    MBEMeshOptimizationOptions options = self.selectedOptimizationOptions;
    if (renderPath == MBERenderPathMeshlet) {
        options |= MBEMeshOptimizationOptionMeshlets;
    } else {
        options &= ~(MBEMeshOptimizationOptionMeshlets | MBEMeshOptimizationOptionOptimizeMeshlet);
    }
    return options;
}

- (MBEMesh *)newMeshWithOptimizationOptions:(MBEMeshOptimizationOptions)optimizationOptions {
    NSUInteger compositionIndex = MIN(self.selectedMeshletCompositionPresetIndex, kMeshletCompositionPresetCount - 1);
    MBEMeshletCompositionPreset composition = kMeshletCompositionPresets[compositionIndex];
    return [[MBEMesh alloc] initWithOBJURL:self.assetURL
                                    device:self.device
                     meshletMaxVertexCount:composition.maxVertexCount
                   meshletMaxTriangleCount:composition.maxTriangleCount
                       optimizationOptions:optimizationOptions];
}

- (void)rebuildMeshForRenderPath:(MBERenderPath)renderPath effectiveOptions:(MBEMeshOptimizationOptions)effectiveOptions {
    if (self.isRebuildingMesh) {
        return;
    }

    self.isRebuildingMesh = YES;
    BOOL wasPaused = self.mtkView.paused;
    self.mtkView.paused = YES;
    [self setRebuildControlsEnabled:NO];

    id<MTLCommandBuffer> commandBuffer = self.lastSubmittedCommandBuffer;
    if (commandBuffer != nil && commandBuffer.status < MTLCommandBufferStatusCompleted) {
        [commandBuffer waitUntilCompleted];
    }

    MBEMesh *mesh = [self newMeshWithOptimizationOptions:effectiveOptions];
    if (mesh != nil) {
        MBERenderPath previousRenderPath = self.renderer.renderPath;
        self.renderer.mesh = mesh;
        self.renderer.renderPath = renderPath;
        if (previousRenderPath != renderPath) {
            [self.renderer invalidateHiZ];
        }
        self.renderPathControl.selectedSegment = renderPath;
        self.currentEffectiveOptimizationOptions = effectiveOptions;
    } else {
        self.renderPathControl.selectedSegment = self.renderer.renderPath;
        NSLog(@"Keeping previous mesh after rebuild failed");
    }

    self.isRebuildingMesh = NO;
    [self updateMeshletCullingControlVisibility];
    [self updateOptimizationControlStateForRenderPath:self.renderer.renderPath];
    [self resetStatsWindow];
    self.mtkView.paused = wasPaused;
}

- (void)setRebuildControlsEnabled:(BOOL)enabled {
    for (NSControl *control in self.rebuildControls) {
        control.enabled = enabled;
    }
    if (enabled) {
        [self updateOptimizationControlStateForRenderPath:self.renderer.renderPath];
    }
}

- (void)updateOptimizationControlStateForRenderPath:(MBERenderPath)renderPath {
    BOOL meshletMode = renderPath == MBERenderPathMeshlet;
    BOOL controlsEnabled = !self.isRebuildingMesh;

    self.remapControl.state = (self.selectedOptimizationOptions & MBEMeshOptimizationOptionRemap) ? NSControlStateValueOn : NSControlStateValueOff;
    self.vertexCacheControl.state = (self.selectedOptimizationOptions & MBEMeshOptimizationOptionVertexCache) ? NSControlStateValueOn : NSControlStateValueOff;
    self.overdrawControl.state = (self.selectedOptimizationOptions & MBEMeshOptimizationOptionOverdraw) ? NSControlStateValueOn : NSControlStateValueOff;
    self.vertexFetchControl.state = (self.selectedOptimizationOptions & MBEMeshOptimizationOptionVertexFetch) ? NSControlStateValueOn : NSControlStateValueOff;
    self.meshletsControl.state = meshletMode ? NSControlStateValueOn : NSControlStateValueOff;
    self.optimizeMeshletControl.state = (meshletMode && (self.selectedOptimizationOptions & MBEMeshOptimizationOptionOptimizeMeshlet)) ? NSControlStateValueOn : NSControlStateValueOff;
    if (self.meshletCompositionPopup.indexOfSelectedItem != self.selectedMeshletCompositionPresetIndex) {
        [self.meshletCompositionPopup selectItemAtIndex:self.selectedMeshletCompositionPresetIndex];
    }
    self.meshletCullingControl.selectedSegment = self.renderer.meshletCullingMode;
    self.vspsCullingControl.selectedSegment = self.renderer.vspsCullingMode;

    self.renderPathControl.enabled = controlsEnabled;
    self.meshletCullingControl.enabled = controlsEnabled && meshletMode;
    self.vspsCullingControl.enabled = controlsEnabled && !meshletMode;
    self.remapControl.enabled = controlsEnabled;
    self.vertexCacheControl.enabled = controlsEnabled;
    self.overdrawControl.enabled = controlsEnabled;
    self.vertexFetchControl.enabled = controlsEnabled;
    self.meshletsControl.enabled = NO;
    self.optimizeMeshletControl.enabled = controlsEnabled && meshletMode;
    self.meshletCompositionPopup.enabled = controlsEnabled && meshletMode;
}

- (void)resetStatsWindow {
    self.statsFrameCount = 0;
    self.statsWindowStartTime = CACurrentMediaTime();
    self.latestGPUFrameMS = 0.0;
}

- (void)configureBenchmarkIfRequested {
    NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
    if (!MBEEnvironmentFlagEnabled(environment[@"MBE_BENCHMARK"])) {
        return;
    }

    self.benchmarkMode = YES;
    self.benchmarkWarmupFrames = MBEEnvironmentUnsignedValue(environment[@"MBE_BENCHMARK_WARMUP"], 60);
    self.benchmarkSampleFrames = MBEEnvironmentUnsignedValue(environment[@"MBE_BENCHMARK_FRAMES"], 120);
    NSUInteger benchmarkFPS = MBEEnvironmentUnsignedValue(environment[@"MBE_BENCHMARK_FPS"], 240);
    NSString *outputPath = environment[@"MBE_BENCHMARK_OUTPUT"];
    if (outputPath.length == 0) {
        outputPath = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:@"benchmark_results.csv"];
    }
    self.benchmarkOutputPath = outputPath;
    self.benchmarkRows = [NSMutableArray arrayWithObject:@"case_index,case,scene,render_path,cull_mode,opt_preset,opt_flags,meshlet_vertices,meshlet_triangles,resolution,frame,cpu_ms,gpu_ms,vertices,indices,triangles,meshlets,visible_instances,total_instances"];
    self.benchmarkCases = [self makeBenchmarkCases];

    self.mtkView.enableSetNeedsDisplay = NO;
    self.mtkView.paused = NO;
    self.mtkView.preferredFramesPerSecond = (NSInteger)benchmarkFPS;

    NSLog(@"Benchmark enabled: %lu cases, warmup=%lu frames, samples=%lu frames, fps=%lu, output=%@",
          (unsigned long)self.benchmarkCases.count,
          (unsigned long)self.benchmarkWarmupFrames,
          (unsigned long)self.benchmarkSampleFrames,
          (unsigned long)benchmarkFPS,
          self.benchmarkOutputPath);
    [self beginBenchmarkCaseAtIndex:0];
}

- (NSArray<MBEBenchmarkCase *> *)makeBenchmarkCases {
    const MBEMeshOptimizationOptions vspsOptions[] = {
        0,
        MBEMeshOptimizationOptionRemap,
        MBEMeshOptimizationOptionRemap |
            MBEMeshOptimizationOptionVertexCache |
            MBEMeshOptimizationOptionOverdraw |
            MBEMeshOptimizationOptionVertexFetch,
    };
    const MBEMeshOptimizationOptions meshletOptions[] = {
        MBEMeshOptimizationOptionMeshlets,
        MBEMeshOptimizationOptionRemap | MBEMeshOptimizationOptionMeshlets,
        MBEMeshOptimizationOptionRemap |
            MBEMeshOptimizationOptionVertexCache |
            MBEMeshOptimizationOptionOverdraw |
            MBEMeshOptimizationOptionVertexFetch |
            MBEMeshOptimizationOptionMeshlets |
            MBEMeshOptimizationOptionOptimizeMeshlet,
    };
    NSArray<NSString *> *optimizationNames = @[ @"raw", @"remap", @"all_on" ];

    NSMutableArray<MBEBenchmarkCase *> *cases = [NSMutableArray array];
    NSArray<NSNumber *> *vspsRenderPaths = @[ @(MBERenderPathIndexedVSPS), @(MBERenderPathVertexPullingVSPS) ];
    NSArray<NSNumber *> *vspsCullingModes = @[
        @(MBEVSPSCullingModeNone),
        @(MBEVSPSCullingModeCPUFrustum),
        @(MBEVSPSCullingModeGPUFrustum),
        @(MBEVSPSCullingModeGPUHiZ),
    ];
    NSArray<NSNumber *> *meshletCullingModes = @[
        @(MBEMeshletCullingModeNone),
        @(MBEMeshletCullingModeFrustum),
        @(MBEMeshletCullingModeFull),
        @(MBEMeshletCullingModeFullHiZ),
    ];

    for (NSNumber *renderPathNumber in vspsRenderPaths) {
        MBERenderPath renderPath = (MBERenderPath)renderPathNumber.integerValue;
        for (NSUInteger optimizationIndex = 0; optimizationIndex < optimizationNames.count; ++optimizationIndex) {
            for (NSNumber *cullingModeNumber in vspsCullingModes) {
                MBEVSPSCullingMode cullingMode = (MBEVSPSCullingMode)cullingModeNumber.integerValue;
                NSString *name = [NSString stringWithFormat:@"%@/%@/%@",
                                  MBERenderPathDisplayName(renderPath),
                                  MBEVSPSCullingModeDisplayName(cullingMode),
                                  optimizationNames[optimizationIndex]];
                [cases addObject:[MBEBenchmarkCase caseWithName:name
                                                     renderPath:renderPath
                                             meshletCullingMode:MBEMeshletCullingModeFull
                                                vspsCullingMode:cullingMode
                                               optimizationName:optimizationNames[optimizationIndex]
                                            optimizationOptions:vspsOptions[optimizationIndex]]];
            }
        }
    }

    for (NSUInteger optimizationIndex = 0; optimizationIndex < optimizationNames.count; ++optimizationIndex) {
        for (NSNumber *cullingModeNumber in meshletCullingModes) {
            MBEMeshletCullingMode cullingMode = (MBEMeshletCullingMode)cullingModeNumber.integerValue;
            NSString *name = [NSString stringWithFormat:@"%@/%@/%@",
                              MBERenderPathDisplayName(MBERenderPathMeshlet),
                              MBEMeshletCullingModeDisplayName(cullingMode),
                              optimizationNames[optimizationIndex]];
            [cases addObject:[MBEBenchmarkCase caseWithName:name
                                                 renderPath:MBERenderPathMeshlet
                                         meshletCullingMode:cullingMode
                                            vspsCullingMode:MBEVSPSCullingModeCPUFrustum
                                           optimizationName:optimizationNames[optimizationIndex]
                                        optimizationOptions:meshletOptions[optimizationIndex]]];
        }
    }

    return cases;
}

- (void)beginBenchmarkCaseAtIndex:(NSUInteger)caseIndex {
    if (caseIndex >= self.benchmarkCases.count) {
        [self finishBenchmark];
        return;
    }

    self.mtkView.paused = YES;
    id<MTLCommandBuffer> commandBuffer = self.lastSubmittedCommandBuffer;
    if (commandBuffer != nil && commandBuffer.status < MTLCommandBufferStatusCompleted) {
        [commandBuffer waitUntilCompleted];
    }

    MBEBenchmarkCase *benchmarkCase = self.benchmarkCases[caseIndex];
    self.benchmarkCaseIndex = caseIndex;
    self.benchmarkSubmittedFrames = 0;
    self.benchmarkCompletedSamples = 0;
    self.selectedOptimizationOptions = benchmarkCase.optimizationOptions;
    self.renderer.renderPath = benchmarkCase.renderPath;
    self.renderer.meshletCullingMode = benchmarkCase.meshletCullingMode;
    self.renderer.vspsCullingMode = benchmarkCase.vspsCullingMode;
    [self.renderer invalidateHiZ];

    MBEMeshOptimizationOptions effectiveOptions = [self effectiveOptimizationOptionsForRenderPath:benchmarkCase.renderPath];
    if (effectiveOptions != self.currentEffectiveOptimizationOptions) {
        MBEMesh *mesh = [self newMeshWithOptimizationOptions:effectiveOptions];
        if (mesh != nil) {
            self.renderer.mesh = mesh;
            self.currentEffectiveOptimizationOptions = effectiveOptions;
        } else {
            NSLog(@"Benchmark mesh rebuild failed for case %@", benchmarkCase.name);
            [self finishBenchmark];
            return;
        }
    }

    self.renderPathControl.selectedSegment = benchmarkCase.renderPath;
    [self updateMeshletCullingControlVisibility];
    [self updateOptimizationControlStateForRenderPath:benchmarkCase.renderPath];
    [self resetStatsWindow];

    NSLog(@"Benchmark case %lu/%lu: %@, flags=%@",
          (unsigned long)(caseIndex + 1),
          (unsigned long)self.benchmarkCases.count,
          benchmarkCase.name,
          MBEOptimizationOptionsCSVName(effectiveOptions));
    self.mtkView.paused = NO;
}

- (void)appendBenchmarkSampleForCase:(MBEBenchmarkCase *)benchmarkCase
                           caseIndex:(NSUInteger)caseIndex
                         sampleIndex:(NSUInteger)sampleIndex
                            cpuFrame:(double)cpuFrameMS
                            gpuFrame:(double)gpuFrameMS
                     visibleInstances:(NSString *)visibleInstances
                           resolution:(CGSize)resolution {
    MBEMesh *mesh = self.renderer.mesh;
    if (mesh == nil) {
        return;
    }

    NSString *cullingName = benchmarkCase.renderPath == MBERenderPathMeshlet
        ? MBEMeshletCullingModeDisplayName(benchmarkCase.meshletCullingMode)
        : MBEVSPSCullingModeDisplayName(benchmarkCase.vspsCullingMode);
    NSString *resolutionString = [NSString stringWithFormat:@"%.0fx%.0f", resolution.width, resolution.height];
    NSString *row = [NSString stringWithFormat:@"%lu,%@,kitten,%@,%@,%@,%@,%lu,%lu,%@,%lu,%.4f,%.4f,%lu,%lu,%lu,%lu,%@,%lu",
                     (unsigned long)caseIndex,
                     benchmarkCase.name,
                     MBERenderPathDisplayName(benchmarkCase.renderPath),
                     cullingName,
                     benchmarkCase.optimizationName,
                     MBEOptimizationOptionsCSVName(mesh.optimizationOptions),
                     (unsigned long)mesh.meshletMaxVertexCount,
                     (unsigned long)mesh.meshletMaxTriangleCount,
                     resolutionString,
                     (unsigned long)sampleIndex,
                     cpuFrameMS,
                     gpuFrameMS,
                     (unsigned long)mesh.vertexCount,
                     (unsigned long)mesh.indexCount,
                     (unsigned long)mesh.triangleCount,
                     (unsigned long)mesh.meshletCount,
                     visibleInstances,
                     (unsigned long)self.renderer.totalInstanceCount];
    [self.benchmarkRows addObject:row];
}

- (void)finishBenchmark {
    if (!self.benchmarkMode) {
        return;
    }

    self.benchmarkMode = NO;
    self.mtkView.paused = YES;

    NSString *csv = [self.benchmarkRows componentsJoinedByString:@"\n"];
    csv = [csv stringByAppendingString:@"\n"];
    NSError *error = nil;
    NSString *outputDirectory = self.benchmarkOutputPath.stringByDeletingLastPathComponent;
    [NSFileManager.defaultManager createDirectoryAtPath:outputDirectory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:&error];
    if (error != nil) {
        NSLog(@"Failed to create benchmark output directory %@: %@", outputDirectory, error);
        error = nil;
    }

    BOOL wroteFile = [csv writeToFile:self.benchmarkOutputPath
                           atomically:YES
                             encoding:NSUTF8StringEncoding
                                error:&error];
    if (wroteFile) {
        NSLog(@"Benchmark finished: wrote %@ (%lu samples)",
              self.benchmarkOutputPath,
              (unsigned long)(self.benchmarkRows.count > 0 ? self.benchmarkRows.count - 1 : 0));
    } else {
        NSLog(@"Failed to write benchmark CSV %@: %@", self.benchmarkOutputPath, error);
    }

    [NSApp terminate:nil];
}

- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size {
    self.renderer.viewport = (MTLViewport){ 0.0, 0.0, size.width, size.height, 0.0, 1.0 };
    [self.renderer invalidateHiZ];
}

- (void)drawInMTKView:(nonnull MTKView *)view {
    if (self.isRebuildingMesh) {
        return;
    }

    BOOL benchmarkMode = self.benchmarkMode;
    NSUInteger benchmarkFrameIndex = 0;
    NSUInteger benchmarkCaseIndex = 0;
    MBEBenchmarkCase *benchmarkCase = nil;
    if (benchmarkMode) {
        if (self.benchmarkCaseIndex >= self.benchmarkCases.count) {
            return;
        }
        NSUInteger benchmarkFrameLimit = self.benchmarkWarmupFrames + self.benchmarkSampleFrames;
        if (self.benchmarkSubmittedFrames >= benchmarkFrameLimit) {
            return;
        }
        benchmarkFrameIndex = self.benchmarkSubmittedFrames + 1;
        benchmarkCaseIndex = self.benchmarkCaseIndex;
        benchmarkCase = self.benchmarkCases[benchmarkCaseIndex];
    }

    CFTimeInterval frameStartTime = CACurrentMediaTime();
    MTLRenderPassDescriptor *renderPass = view.currentRenderPassDescriptor;
    if (renderPass == nil) {
        return; // Didn't get a render pass descriptor; drop this frame
    }
    renderPass.depthAttachment.storeAction = MTLStoreActionStore;

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    [self.renderer prepareFrame];
    [self.renderer encodePreRenderCommandsWithCommandBuffer:commandBuffer];

    id<MTLRenderCommandEncoder> renderCommandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPass];
    [self.renderer draw:renderCommandEncoder];
    [renderCommandEncoder endEncoding];

    if (self.renderer.requiresHiZGeneration) {
        [self.renderer encodeHiZGenerationWithCommandBuffer:commandBuffer
                                               depthTexture:renderPass.depthAttachment.texture];
    }

    [commandBuffer presentDrawable:view.currentDrawable];

    double cpuFrameMS = (CACurrentMediaTime() - frameStartTime) * 1000.0;
    NSString *benchmarkVisibleInstances = nil;
    CGSize benchmarkResolution = view.drawableSize;
    if (benchmarkMode) {
        BOOL gpuVisibleCountUnknown = self.renderer.renderPath != MBERenderPathMeshlet &&
            (self.renderer.vspsCullingMode == MBEVSPSCullingModeGPUFrustum ||
             self.renderer.vspsCullingMode == MBEVSPSCullingModeGPUHiZ);
        benchmarkVisibleInstances = gpuVisibleCountUnknown
            ? @"-1"
            : [NSString stringWithFormat:@"%lu", (unsigned long)self.renderer.cpuVisibleInstanceCount];
        self.benchmarkSubmittedFrames = benchmarkFrameIndex;
    }

    __weak typeof(self) weakSelf = self;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completedCommandBuffer) {
        double gpuFrameMS = 0.0;
        if (completedCommandBuffer.GPUEndTime > completedCommandBuffer.GPUStartTime) {
            gpuFrameMS = (completedCommandBuffer.GPUEndTime - completedCommandBuffer.GPUStartTime) * 1000.0;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            MBEViewController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }

            [strongSelf updateStatsWithGPUFrameMS:gpuFrameMS countFrame:NO];

            if (!benchmarkMode || !strongSelf.benchmarkMode || strongSelf.benchmarkCaseIndex != benchmarkCaseIndex) {
                return;
            }

            if (benchmarkFrameIndex > strongSelf.benchmarkWarmupFrames) {
                NSUInteger sampleIndex = benchmarkFrameIndex - strongSelf.benchmarkWarmupFrames;
                if (sampleIndex <= strongSelf.benchmarkSampleFrames) {
                    [strongSelf appendBenchmarkSampleForCase:benchmarkCase
                                                   caseIndex:benchmarkCaseIndex
                                                 sampleIndex:sampleIndex
                                                    cpuFrame:cpuFrameMS
                                                    gpuFrame:gpuFrameMS
                                             visibleInstances:benchmarkVisibleInstances
                                                   resolution:benchmarkResolution];
                    strongSelf.benchmarkCompletedSamples += 1;
                }

                if (strongSelf.benchmarkCompletedSamples >= strongSelf.benchmarkSampleFrames) {
                    [strongSelf beginBenchmarkCaseAtIndex:benchmarkCaseIndex + 1];
                }
            }
        });
    }];

    [commandBuffer commit];
    self.lastSubmittedCommandBuffer = commandBuffer;

    self.latestCPUFrameMS = cpuFrameMS;
    [self updateStatsWithGPUFrameMS:self.latestGPUFrameMS countFrame:YES];
}

- (void)updateStatsWithGPUFrameMS:(double)gpuFrameMS countFrame:(BOOL)countFrame {
    if (gpuFrameMS > 0.0) {
        self.latestGPUFrameMS = gpuFrameMS;
    }

    if (countFrame) {
        self.statsFrameCount += 1;
    }

    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval elapsed = now - self.statsWindowStartTime;
    if (elapsed < 0.25) {
        return;
    }

    self.currentFPS = self.statsFrameCount / elapsed;
    self.statsFrameCount = 0;
    self.statsWindowStartTime = now;

    NSString *gpuString = self.latestGPUFrameMS > 0.0
        ? [NSString stringWithFormat:@"%.2f", self.latestGPUFrameMS]
        : @"--";

    NSString *cullingString = self.renderer.renderPath == MBERenderPathMeshlet
        ? MBEMeshletCullingModeDisplayName(self.renderer.meshletCullingMode)
        : MBEVSPSCullingModeDisplayName(self.renderer.vspsCullingMode);

    NSString *instanceString = (self.renderer.renderPath != MBERenderPathMeshlet &&
                                (self.renderer.vspsCullingMode == MBEVSPSCullingModeGPUFrustum ||
                                 self.renderer.vspsCullingMode == MBEVSPSCullingModeGPUHiZ))
        ? [NSString stringWithFormat:@"GPU/%lu", (unsigned long)self.renderer.totalInstanceCount]
        : [NSString stringWithFormat:@"%lu/%lu",
           (unsigned long)self.renderer.cpuVisibleInstanceCount,
           (unsigned long)self.renderer.totalInstanceCount];

    self.statsLabel.stringValue = [NSString stringWithFormat:@"Mode: %@\nCull: %@\nFPS: %.1f\nCPU: %.2f ms\nGPU: %@ ms\nInst: %@",
                                   MBERenderPathDisplayName(self.renderer.renderPath),
                                   cullingString,
                                   self.currentFPS,
                                   self.latestCPUFrameMS,
                                   gpuString,
                                   instanceString];
}

@end
