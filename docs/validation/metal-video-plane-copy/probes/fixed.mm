#import <AVFoundation/AVFoundation.h>
#include <CommonCrypto/CommonDigest.h>
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
    [enc copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(w,h,1) toTexture:dst destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [enc generateMipmapsForTexture:dst]; [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.error) NSLog(@"%@",cb.error);
    CHECK(cb.status==MTLCommandBufferStatusCompleted);
    std::vector<uint8_t> ref(w*h*bpp);
    CHECK(CVPixelBufferLockBaseAddress(frame,kCVPixelBufferLock_ReadOnly)==0);
    const auto *base=(const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(frame,p);
    size_t pitch=CVPixelBufferGetBytesPerRowOfPlane(frame,p);
    for (unsigned y=0; y<h; y++) memcpy(ref.data()+y*w*bpp,base+y*pitch,w*bpp);
    CVPixelBufferUnlockBaseAddress(frame,kCVPixelBufferLock_ReadOnly);
    size_t total=0;
    for (unsigned l=0; l<dst.mipmapLevelCount; ++l) {
        std::vector<uint8_t> got(ref.size(),0xdd);
        [dst getBytes:got.data() bytesPerRow:w*bpp fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:l];
        if (ref!=got) {
            auto diff=std::mismatch(ref.begin(),ref.end(),got.begin());
            fprintf(stderr,"plane %u level %u index %td: expected %u got %u\n",p,l,diff.first-ref.begin(),*diff.first,*diff.second);
            return 1;
        }
        total+=ref.size();
        unsigned nw=std::max(1u,w/2), nh=std::max(1u,h/2);
        std::vector<uint8_t> next(nw*nh*bpp);
        for (unsigned y=0; y<nh; ++y) for(unsigned x=0; x<nw; ++x) {
            unsigned left=2*x, right=std::min(w-1,left+1), top=2*y, bottom=std::min(h-1,top+1);
            for(unsigned c=0; c<bpp; ++c) {
                unsigned a=ref[(top*w+left)*bpp+c];
                next[(y*nw+x)*bpp+c]=p ? (a+ref[(top*w+right)*bpp+c]+ref[(bottom*w+left)*bpp+c]+ref[(bottom*w+right)*bpp+c]+2)/4 : a;
            }
        }
        w=nw; h=nh; ref.swap(next);
    }
    printf("plane %u %s: %lu levels, %zu bytes matched including level zero\n",p,p?"RG16":"R16",(unsigned long)dst.mipmapLevelCount,total); return 0;
}
#include <chrono>
static int measure(id<MTLDevice> dev, id<MTLCommandQueue> queue, CVPixelBufferRef frame) {
    id<MTLTexture> dst[2];
    for (unsigned p = 0; p < 2; ++p) {
        auto td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:p ? MTLPixelFormatRG16Unorm : MTLPixelFormatR16Unorm
            width:3840u >> p height:2160u >> p mipmapped:YES];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeManaged;
        dst[p] = [dev newTextureWithDescriptor:td];
        CHECK(candidateObject(dst[p],dev) && [(NSObject *)dst[p] mipInVram:0]);
    }
    for (unsigned i = 0; i < 15; ++i) @autoreleasepool {
         CHECK(frame && CVPixelBufferGetPlaneCount(frame)==2);
        id<MTLTexture> src[2];
        for (unsigned p = 0; p < 2; ++p) {
            auto d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:dst[p].pixelFormat
                      width:dst[p].width height:dst[p].height mipmapped:NO];
            d.usage = MTLTextureUsageShaderRead;
            src[p] = [dev newTextureWithDescriptor:d iosurface:CVPixelBufferGetIOSurface(frame) plane:p];
            CHECK(candidateObject(src[p],dev));
        }
        for (bool upload : {true,false}) {
            const auto begin = std::chrono::steady_clock::now();
            auto cmd = [queue commandBuffer];
            auto enc = [cmd blitCommandEncoder];
            CHECK(candidateObject(enc,dev));
            for (unsigned p = 0; p < 2; ++p) {
                if (upload) {
                    [enc copyFromTexture:src[p] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                        sourceSize:MTLSizeMake(src[p].width,src[p].height,1) toTexture:dst[p]
                        destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
                }
                [enc generateMipmapsForTexture:dst[p]];
            }
            [enc endEncoding]; [cmd commit]; [cmd waitUntilCompleted];
            double ms = std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();
            CHECK(cmd.status == MTLCommandBufferStatusCompleted);
            if (i >= 3) printf("%u,%s,%.6f\n",i,upload ? "copy_and_mips" : "mips",ms);
        }
        if (i == 14) for (unsigned p=0; p<2; ++p) CHECK(checkPlane(dev,queue,frame,p)==0);
    }
    return 0;
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
    CHECK(CVPixelBufferLockBaseAddress(frame,kCVPixelBufferLock_ReadOnly)==0);
    CC_SHA256_CTX hash; CC_SHA256_Init(&hash);
    for (unsigned p=0;p<2;p++) {
        auto pixels=(const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(frame,p);
        for(unsigned y=0;y<CVPixelBufferGetHeightOfPlane(frame,p);y++)
            CC_SHA256_Update(&hash,pixels+y*CVPixelBufferGetBytesPerRowOfPlane(frame,p),CVPixelBufferGetWidthOfPlane(frame,p)*(p?4:2));
    }
    uint8_t digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest,&hash);
    printf("FRAME "); for (auto byte : digest) printf("%02x",byte); puts("");
    CVPixelBufferUnlockBaseAddress(frame,kCVPixelBufferLock_ReadOnly);
    CHECK(measure(dev,q,frame)==0); CFRelease(sample); [reader cancelReading]; return 0;
} }
