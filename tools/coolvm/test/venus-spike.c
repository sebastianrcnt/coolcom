/* No guest/vCPU: real Venus wire calls, HOST3D blobs and Hypervisor mapping. */
#include <Hypervisor/Hypervisor.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <virglrenderer.h>
#include "vn_protocol_driver.h"
#define CHECK(x) do { int r_=(x); if(r_){fprintf(stderr,"%s: %d (0x%x)\n",#x,r_,r_);exit(1);} } while(0)
static void fence(void *cookie,uint32_t ctx,uint32_t ring,uint64_t id)
{ (void)cookie;(void)ctx;(void)ring;(void)id; }
static struct vn_cs_encoder enc;
static void *reply;
static struct vn_cs_decoder submit(void)
{
    CHECK(virgl_renderer_submit_cmd(enc.data,1,(int)(enc.len/4)));
    enc.len=0;
    return (struct vn_cs_decoder){reply,16384,0};
}
static void seek(void)
{ memset(reply,0xcc,16384); vn_encode_vkSeekReplyCommandStreamMESA(&enc,0,0); }
static void *blob(uint32_t id,uint64_t memory)
{
    struct virgl_renderer_resource_create_blob_args args={.res_handle=id,.ctx_id=1,
        .blob_mem=VIRGL_RENDERER_BLOB_MEM_HOST3D,.blob_flags=VIRGL_RENDERER_BLOB_FLAG_USE_MAPPABLE,
        .blob_id=memory,.size=16384};
    CHECK(virgl_renderer_resource_create_blob(&args));
    uint64_t ptr=0;CHECK(virgl_renderer_resource_get_map_ptr(id,&ptr));
    assert(ptr && !(ptr%getpagesize()));
    void *standard=NULL;uint64_t size=0;
    int standard_result=virgl_renderer_resource_map(id,&standard,&size);
    printf("standard resource_map: %d (macOS uses get_map_ptr)\n",standard_result);
    assert(standard_result==-22);
    uint32_t info=0;CHECK(virgl_renderer_resource_get_map_info(id,&info));
    printf("blob %u: ptr=%p cache=%u aligned=%d\n",id,(void *)(uintptr_t)ptr,info,getpagesize());
    return (void *)(uintptr_t)ptr;
}
static void map(void *ptr,uint64_t ipa)
{
    CHECK(hv_vm_map(ptr,ipa,16384,HV_MEMORY_READ|HV_MEMORY_WRITE));
    memset(ptr,0x5a,16384);
    CHECK(hv_vm_unmap(ipa,16384));
    puts("hv_vm_map/unmap PASS (no guest access tested)");
}
int main(void)
{
    setvbuf(stdout,NULL,_IONBF,0);
    struct virgl_renderer_callbacks cb={.version=3,.write_context_fence=fence};
    CHECK(virgl_renderer_init(&cb,VIRGL_RENDERER_VENUS|VIRGL_RENDERER_NO_VIRGL|
        VIRGL_RENDERER_THREAD_SYNC|VIRGL_RENDERER_ASYNC_FENCE_CB,&cb));
    uint32_t version,size;virgl_renderer_get_cap_set(4,&version,&size);assert(size);
    printf("Venus capset: version=%u bytes=%u\n",version,size);
    CHECK(virgl_renderer_context_create_with_flags(1,4,5,"spike"));
    CHECK(hv_vm_create(NULL));
    reply=blob(1,0);map(reply,0xa00000000ULL);
    /* RESOURCE_CREATE_BLOB already attaches a HOST3D blob to its context. */
    VkCommandStreamDescriptionMESA stream={.resourceId=1,.size=16384};
    vn_encode_vkSetReplyCommandStreamMESA(&enc,0,&stream);submit();
    VkInstance instance=(VkInstance)(uintptr_t)1;
    VkApplicationInfo app={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.apiVersion=VK_API_VERSION_1_1};
    VkInstanceCreateInfo ci={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&app};
    seek();vn_encode_vkCreateInstance(&enc,VK_COMMAND_GENERATE_REPLY_BIT_EXT,&ci,NULL,&instance);
    struct vn_cs_decoder dec=submit();CHECK(vn_decode_vkCreateInstance_reply(&dec,&ci,NULL,&instance));
    uint32_t count=1;VkPhysicalDevice physical=(VkPhysicalDevice)(uintptr_t)2;
    seek();vn_encode_vkEnumeratePhysicalDevices(&enc,VK_COMMAND_GENERATE_REPLY_BIT_EXT,instance,&count,&physical);
    dec=submit();CHECK(vn_decode_vkEnumeratePhysicalDevices_reply(&dec,instance,&count,&physical));assert(count==1);
    VkPhysicalDeviceMemoryProperties props;
    seek();vn_encode_vkGetPhysicalDeviceMemoryProperties(&enc,VK_COMMAND_GENERATE_REPLY_BIT_EXT,physical,&props);
    dec=submit();vn_decode_vkGetPhysicalDeviceMemoryProperties_reply(&dec,physical,&props);
    uint32_t type=0;while(type<props.memoryTypeCount && !(props.memoryTypes[type].propertyFlags&VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT))type++;
    assert(type<props.memoryTypeCount);
    float priority=1;VkDeviceQueueCreateInfo qi={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueCount=1,.pQueuePriorities=&priority};
    VkDeviceCreateInfo di={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&qi};
    VkDevice device=(VkDevice)(uintptr_t)3;
    seek();vn_encode_vkCreateDevice(&enc,VK_COMMAND_GENERATE_REPLY_BIT_EXT,physical,&di,NULL,&device);
    dec=submit();CHECK(vn_decode_vkCreateDevice_reply(&dec,physical,&di,NULL,&device));
    VkMemoryAllocateInfo ai={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=16384,.memoryTypeIndex=type};
    VkDeviceMemory memory=(VkDeviceMemory)(uintptr_t)4;
    seek();vn_encode_vkAllocateMemory(&enc,VK_COMMAND_GENERATE_REPLY_BIT_EXT,device,&ai,NULL,&memory);
    dec=submit();CHECK(vn_decode_vkAllocateMemory_reply(&dec,device,&ai,NULL,&memory));
    map(blob(2,4),0xa00004000ULL);
    virgl_renderer_resource_unref(2);
    vn_encode_vkFreeMemory(&enc,0,device,memory,NULL);
    vn_encode_vkDestroyDevice(&enc,0,device,NULL);
    vn_encode_vkDestroyInstance(&enc,0,instance,NULL);submit();
    virgl_renderer_resource_unref(1);virgl_renderer_context_destroy(1);
    virgl_renderer_cleanup(&cb);CHECK(hv_vm_destroy());
    puts("venus-spike: Venus VkDeviceMemory HOST3D mapping PASS");
    return 0;
}
