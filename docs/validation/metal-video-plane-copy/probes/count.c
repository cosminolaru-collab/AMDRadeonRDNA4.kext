#include <IOKit/IOKitLib.h>
#include <stdatomic.h>
#include <stdio.h>
#include "rdna4compute.h"
static _Atomic unsigned dispatches[4], writes;
static _Atomic unsigned long long bytes;
static kern_return_t method(mach_port_t c,uint32_t s,const uint64_t *a,uint32_t n,
    const void *b,size_t z,uint64_t *o,uint32_t *no,void *out,size_t *nz) {
    kern_return_t kr=IOConnectCallMethod(c,s,a,n,b,z,o,no,out,nz);
    if (!kr && s==kRDNA4MethodDispatch && z==sizeof(RDNA4Dispatch)) {
        const RDNA4Dispatch *d=b;
        unsigned x=d->groupSize[0], y=d->groupSize[1];
        if(x==16 && y==8) atomic_fetch_add(&dispatches[0],1);
        if(x==128 && y==1) atomic_fetch_add(&dispatches[1],1);
        if(x==256 && y==1) atomic_fetch_add(&dispatches[2],1);
        if(x==64 && y==1) atomic_fetch_add(&dispatches[3],1);
    }
    return kr;
}
static kern_return_t scalar(mach_port_t c,uint32_t s,const uint64_t *a,uint32_t n,uint64_t *o,uint32_t *no) {
    kern_return_t kr=IOConnectCallScalarMethod(c,s,a,n,o,no);
    if(!kr && s==kRDNA4MethodWrite && n==4) {
        atomic_fetch_add(&writes,1);
        atomic_fetch_add(&bytes,a[3]);
    }
    return kr;
}
__attribute__((destructor)) static void counts(void) {
    fprintf(stderr,"COUNTS one_level=%u grouped_tail=%u whole_chain=%u gpu_plane_copy=%u host_writes=%u host_write_bytes=%llu\n",
        atomic_load(&dispatches[0]),atomic_load(&dispatches[1]),atomic_load(&dispatches[2]),atomic_load(&dispatches[3]),atomic_load(&writes),atomic_load(&bytes));
}
__attribute__((used,section("__DATA,__interpose"))) static const struct {const void *f,*orig;} hooks[]={
    {(const void*)method,(const void*)IOConnectCallMethod},{(const void*)scalar,(const void*)IOConnectCallScalarMethod}};
