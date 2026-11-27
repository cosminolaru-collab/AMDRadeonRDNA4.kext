#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#define main marker_main
#include "test.mm"
#undef main

@interface NSObject (ProbeStorage)
- (BOOL)mipInVram:(NSUInteger)level;
@end

static bool candidateObject(id obj, id dev) {
    if (!obj) return false;
    struct stat a={},b={};
    return stat(class_getImageName(object_getClass(obj)),&a)==0 &&
           stat(class_getImageName(object_getClass(dev)),&b)==0 && a.st_dev==b.st_dev && a.st_ino==b.st_ino;
}

static int checkPlane(id<MTLDevice> dev, id<MTLCommandQueue> queue, CVPixelBufferRef frame, unsigned p) {
    unsigned w=CVPixelBufferGetWidthOfPlane(frame,p), h=CVPixelBufferGetHeightOfPlane(frame,p), bpp=p ? 4 : 2;
    CHECK(w==(3840u>>p) && h==(2160u>>p));
    auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:p ? MTLPixelFormatRG16Unorm : MTLPixelFormatR16Unorm width:w height:h mipmapped:NO];
    desc.usage=MTLTextureUsageShaderRead;
    auto src=[dev newTextureWithDescriptor:desc iosurface:CVPixelBufferGetIOSurface(frame) plane:p];
    auto dstDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:desc.pixelFormat width:w height:h mipmapped:YES];
    dstDesc.storageMode=MTLStorageModeManaged; dstDesc.usage=MTLTextureUsageShaderRead;
    auto dst=[dev newTextureWithDescriptor:dstDesc];
    CHECK(candidateObject(src,dev) && candidateObject(dst,dev) && candidateObject(queue,dev));
    CHECK([(NSObject *)dst mipInVram:0]);
    auto cb=[queue commandBuffer]; auto enc=[cb blitCommandEncoder];
    CHECK(candidateObject(enc,dev) && candidateObject(cb,dev));
    const unsigned sw=17, sh=9, dx=3, dy=5, sx=7, sy=11;
    std::vector<uint8_t> sentinel((sw+2)*(sh+2)*bpp,0xc7);
    auto border=MTLRegionMake2D(dx-1,dy-1,sw+2,sh+2);
    [dst replaceRegion:border mipmapLevel:0 withBytes:sentinel.data() bytesPerRow:(sw+2)*bpp];
    [enc copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(sx,sy,0)
              sourceSize:MTLSizeMake(sw,sh,1) toTexture:dst destinationSlice:0 destinationLevel:0
              destinationOrigin:MTLOriginMake(dx,dy,0)];
    [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.error) NSLog(@"%@",cb.error);
    CHECK(cb.status==MTLCommandBufferStatusCompleted);
    std::vector<uint8_t> ref(w*h*bpp);
    CHECK(CVPixelBufferLockBaseAddress(frame,kCVPixelBufferLock_ReadOnly)==0);
    const auto *base=(const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(frame,p);
    size_t pitch=CVPixelBufferGetBytesPerRowOfPlane(frame,p);
    for (unsigned y=0; y<h; y++) memcpy(ref.data()+y*w*bpp,base+y*pitch,w*bpp);
    CVPixelBufferUnlockBaseAddress(frame,kCVPixelBufferLock_ReadOnly);
    for(unsigned y=0; y<sh; ++y)
        memcpy(sentinel.data()+((y+1)*(sw+2)+1)*bpp,ref.data()+((y+sy)*w+sx)*bpp,sw*bpp);
    std::vector<uint8_t> got(sentinel.size());
    [dst getBytes:got.data() bytesPerRow:(sw+2)*bpp fromRegion:border mipmapLevel:0];
    CHECK(got==sentinel);
    printf("plane %u: partial blit and all four border edges passed\n",p); return 0;
}
int main(int argc,char **argv) { @autoreleasepool {
    CHECK(argc==3 && dlopen(argv[1],RTLD_NOW|RTLD_LOCAL));
    Class cls=NSClassFromString(@"RDNA4MTLDevice"); struct stat a={},b={};
    CHECK(cls && stat(class_getImageName(cls),&a)==0 && stat(argv[1],&b)==0 && a.st_dev==b.st_dev && a.st_ino==b.st_ino);
    auto service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("RDNA4Accelerator")); CHECK(service);
    id<MTLDevice> dev=[[cls alloc] initNativeWithAcceleratorPort:service]; IOObjectRelease(service); CHECK(dev);
    auto asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]] options:nil];
    auto track=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject; CHECK(track);
    NSError *err=nil; auto reader=[[AVAssetReader alloc] initWithAsset:asset error:&err]; CHECK(reader);
    auto out=[AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),(id)kCVPixelBufferIOSurfacePropertiesKey:@{}}];
    out.alwaysCopiesSampleData=NO; [reader addOutput:out]; CHECK([reader startReading]);
    auto sample=[out copyNextSampleBuffer]; if(!sample) NSLog(@"%@",reader.error); CHECK(sample);
    auto frame=CMSampleBufferGetImageBuffer(sample); CHECK(frame && CVPixelBufferGetIOSurface(frame) && CVPixelBufferGetPlaneCount(frame)==2);
    CHECK(CVPixelBufferGetPixelFormatType(frame)==kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
    auto q=[dev newCommandQueue]; CHECK(q);
    for (unsigned p=0;p<2;++p) CHECK(checkPlane(dev,q,frame,p)==0);
    CFRelease(sample); [reader cancelReading]; return 0;
} }
