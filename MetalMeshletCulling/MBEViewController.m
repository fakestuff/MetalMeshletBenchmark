
#import "MBEViewController.h"
#import "MBEMesh.h"
#import "MBEMeshletRenderer.h"

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>

@interface MBEViewController () <MTKViewDelegate>
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) MBEMeshletRenderer *renderer;
@property (nonatomic, weak) MTKView *mtkView;
@property (nonatomic, strong) NSTextField *statsLabel;
@property (nonatomic, strong) NSSegmentedControl *renderPathControl;
@property (nonatomic, assign) NSUInteger statsFrameCount;
@property (nonatomic, assign) CFTimeInterval statsWindowStartTime;
@property (nonatomic, assign) double currentFPS;
@property (nonatomic, assign) double latestCPUFrameMS;
@property (nonatomic, assign) double latestGPUFrameMS;
@end

@implementation MBEViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.device = MTLCreateSystemDefaultDevice();
    self.commandQueue = [self.device newCommandQueue];

    MTKView *mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:self.device];
    mtkView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.view addSubview:mtkView];

    self.mtkView = mtkView;
    self.mtkView.delegate = self;
    self.mtkView.sampleCount = 4;
    self.mtkView.clearColor = MTLClearColorMake(1, 1, 1, 1.0);
    self.mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    self.mtkView.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);

    [self makeStatsOverlay];

    self.renderer = [[MBEMeshletRenderer alloc] initWithDevice:self.device
                                                  commandQueue:self.commandQueue
                                                          view:self.mtkView];

    NSURL *assetURL = [[NSBundle mainBundle] URLForResource:@"kitten" withExtension:@"obj"];
    self.renderer.mesh = [[MBEMesh alloc] initWithOBJURL:assetURL device:self.device];
}

- (void)makeStatsOverlay {
    NSTextField *statsLabel = [NSTextField labelWithString:@"Mode: Meshlet\nFPS: --\nCPU: -- ms\nGPU: -- ms\nInst: --/--"];
    statsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    statsLabel.font = [NSFont monospacedDigitSystemFontOfSize:12.0 weight:NSFontWeightMedium];
    statsLabel.textColor = NSColor.whiteColor;
    statsLabel.maximumNumberOfLines = 5;
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

    [self.view addSubview:statsLabel];
    [self.view addSubview:renderPathBackground];
    [renderPathBackground addSubview:renderPathControl];
    [NSLayoutConstraint activateConstraints:@[
        [statsLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12.0],
        [statsLabel.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:12.0],
        [statsLabel.widthAnchor constraintEqualToConstant:170.0],
        [statsLabel.heightAnchor constraintEqualToConstant:94.0],
        [renderPathBackground.leadingAnchor constraintEqualToAnchor:statsLabel.leadingAnchor],
        [renderPathBackground.topAnchor constraintEqualToAnchor:statsLabel.bottomAnchor constant:8.0],
        [renderPathBackground.widthAnchor constraintEqualToConstant:232.0],
        [renderPathBackground.heightAnchor constraintEqualToConstant:40.0],
        [renderPathControl.centerXAnchor constraintEqualToAnchor:renderPathBackground.centerXAnchor],
        [renderPathControl.centerYAnchor constraintEqualToAnchor:renderPathBackground.centerYAnchor],
        [renderPathControl.widthAnchor constraintEqualToConstant:216.0],
        [renderPathControl.heightAnchor constraintEqualToConstant:28.0],
    ]];

    self.statsLabel = statsLabel;
    self.renderPathControl = renderPathControl;
    self.statsWindowStartTime = CACurrentMediaTime();
}

- (void)renderPathControlChanged:(NSSegmentedControl *)sender {
    self.renderer.renderPath = (MBERenderPath)sender.selectedSegment;
}

- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size {
    self.renderer.viewport = (MTLViewport){ 0.0, 0.0, size.width, size.height, 0.0, 1.0 };
}

- (void)drawInMTKView:(nonnull MTKView *)view {
    CFTimeInterval frameStartTime = CACurrentMediaTime();
    MTLRenderPassDescriptor *renderPass = view.currentRenderPassDescriptor;
    if (renderPass == nil) {
        return; // Didn't get a render pass descriptor; drop this frame
    }

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> renderCommandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPass];
    [self.renderer draw:renderCommandEncoder];
    [renderCommandEncoder endEncoding];
    [commandBuffer presentDrawable:view.currentDrawable];

    __weak typeof(self) weakSelf = self;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completedCommandBuffer) {
        double gpuFrameMS = 0.0;
        if (completedCommandBuffer.GPUEndTime > completedCommandBuffer.GPUStartTime) {
            gpuFrameMS = (completedCommandBuffer.GPUEndTime - completedCommandBuffer.GPUStartTime) * 1000.0;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf updateStatsWithGPUFrameMS:gpuFrameMS countFrame:NO];
        });
    }];

    [commandBuffer commit];

    self.latestCPUFrameMS = (CACurrentMediaTime() - frameStartTime) * 1000.0;
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

    self.statsLabel.stringValue = [NSString stringWithFormat:@"Mode: %@\nFPS: %.1f\nCPU: %.2f ms\nGPU: %@ ms\nInst: %lu/%lu",
                                   MBERenderPathDisplayName(self.renderer.renderPath),
                                   self.currentFPS,
                                   self.latestCPUFrameMS,
                                   gpuString,
                                   (unsigned long)self.renderer.cpuVisibleInstanceCount,
                                   (unsigned long)self.renderer.totalInstanceCount];
}

@end
