#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <sys/stat.h>
#include <cmath>
#include <algorithm>
#include <vector>

@interface NSObject (NativeTest)
- (instancetype)initNativeWithAcceleratorPort:(io_service_t)service;
- (instancetype)initWithDevice:(id)device path:(NSString *)path;
@end
#define CHECK(x) do { if (!(x)) { NSLog(@"failed at %d: %s", __LINE__, #x); return 1; } } while (0)

static int trial(id<MTLDevice> dev, bool control, bool view) {
    id<MTLLibrary> lib=[[NSClassFromString(@"RDNA4MTLLibrary") alloc] initWithDevice:dev path:[NSURL fileURLWithPath:@"probe.metallib"].path];
    auto pd=[MTLRenderPipelineDescriptor new]; pd.vertexFunction=[lib newFunctionWithName:@"triangle"];
    pd.fragmentFunction=[lib newFunctionWithName:@"planes"]; pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
    NSError *err=nil;
    auto pipe=[dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!pipe) NSLog(@"%@",err);
    CHECK(pipe); auto q=[dev newCommandQueue];
    id<MTLTexture> tex[2];
    for (unsigned plane=0; plane<2; ++plane) {
        auto td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:plane ? MTLPixelFormatRG16Unorm : MTLPixelFormatR16Unorm
              width:3840u >> plane height:2160u >> plane mipmapped:YES];
        td.storageMode=MTLStorageModeManaged; td.usage=MTLTextureUsageShaderRead;
        tex[plane]=[dev newTextureWithDescriptor:td]; CHECK(tex[plane]);
        for (unsigned l=0; l<td.mipmapLevelCount; ++l) {
            unsigned w=MAX(1u,(unsigned)td.width>>l),h=MAX(1u,(unsigned)td.height>>l);
            uint16_t v=(l+1)*16*257;
            std::vector<uint16_t> data(w*h*(plane+1),v);
            if (plane) for (size_t n=1; n<data.size(); n+=2) data[n]=65535-v;
            [tex[plane] replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:l withBytes:data.data() bytesPerRow:w*(plane+1)*2];
        }
    }
    if (view) {
        for(unsigned p=0; p<2; ++p) {
            tex[p]=[tex[p] newTextureViewWithPixelFormat:tex[p].pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(2,2) slices:NSMakeRange(0,1)];
            CHECK(tex[p] && tex[p].mipmapLevelCount==2);
        }
    }
    const float pos[]={-1,-1,3,-1,-1,3};
    auto vertices=[dev newBufferWithBytes:pos length:sizeof(pos) options:MTLResourceStorageModeShared];
    for (unsigned width : {240u,160u}) for (unsigned filter : {0u,1u,2u}) {
        unsigned height=width==240 ? 135 : 100;
        auto td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
        td.usage=MTLTextureUsageRenderTarget; td.storageMode=MTLStorageModeShared;
        auto target=[dev newTextureWithDescriptor:td]; CHECK(target);
        auto sd=[MTLSamplerDescriptor new]; sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterLinear; sd.mipFilter=(MTLSamplerMipFilter)filter;
        auto samp=[dev newSamplerStateWithDescriptor:sd]; CHECK(samp);
        auto rp=[MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture=target;
        rp.colorAttachments[0].loadAction=MTLLoadActionClear; rp.colorAttachments[0].storeAction=MTLStoreActionStore;
        auto cb=[q commandBuffer]; auto enc=[cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:pipe]; [enc setVertexBuffer:vertices offset:0 atIndex:0];
        [enc setFragmentTexture:tex[0] atIndex:3]; [enc setFragmentTexture:tex[1] atIndex:5]; [enc setFragmentSamplerState:samp atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
        CHECK(cb.status==MTLCommandBufferStatusCompleted);
        unsigned char px[4]={}; [target getBytes:px bytesPerRow:4 fromRegion:MTLRegionMake2D(width/2,height/2,1,1) mipmapLevel:0];
        double lod=std::log2(3840.0/width);
        double y=control || filter==0 ? 0 : filter==1 ? std::round(lod) : lod;
        double uv=std::max(0.0,y-1.0);
        if (view) { y=std::clamp(y,2.0,3.0); uv=std::clamp(uv,2.0,3.0); }
        printf("%ux%u filter=%u pixel=%u,%u,%u expected=%.1f,%.1f,%.1f\n",width,height,filter,px[0],px[1],px[2],16*(1+y),16*(1+uv),255-16*(1+uv)); fflush(stdout);
        CHECK(std::abs(px[0]-16*(1+y))<=2 && std::abs(px[1]-16*(1+uv))<=2 && std::abs(px[2]-(255-16*(1+uv)))<=2);
    }
    return 0;
}
int main(int argc,char **argv) { @autoreleasepool {
    CHECK(argc==3 && dlopen(argv[1], RTLD_NOW|RTLD_LOCAL));
    Class cls=NSClassFromString(@"RDNA4MTLDevice"); struct stat a={},b={};
    CHECK(cls && stat(class_getImageName(cls),&a)==0 && stat(argv[1],&b)==0 && a.st_dev==b.st_dev && a.st_ino==b.st_ino);
    io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("RDNA4Accelerator")); CHECK(service);
    id<MTLDevice> dev=[[cls alloc] initNativeWithAcceleratorPort:service]; IOObjectRelease(service); CHECK(dev); return trial(dev,!strcmp(argv[2],"control"),!strcmp(argv[2],"view"));
} }
