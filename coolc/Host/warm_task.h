// Owned Warm task jobs; private ABI callbacks have one scalar pointer argument.
#include <setjmp.h>
#include <time.h>
#include <sched.h>
typedef struct {
    pthread_t thread;
    pthread_mutex_t lock;
    pthread_cond_t changed;
    uint8_t (*entry)(void *);
    void *data, *result;
    int64_t state, detached;
    const char *message;
    jmp_buf abort_context;
} WarmHostTask;
static _Thread_local WarmHostTask *warm_current_task;
static void warm_task_free(WarmHostTask *t) {
    host_free((uint8_t *)t->result-8);
    pthread_cond_destroy(&t->changed);pthread_mutex_destroy(&t->lock);host_free(t);
}
static void *warm_task_entry(void *data) {
    WarmHostTask *t=data;warm_current_task=t;
    int64_t state;
    if(!setjmp(t->abort_context)) {t->entry(t->data);state=1;} else state=2;
    warm_current_task=NULL;
    pthread_mutex_lock(&t->lock);
    t->state=state;int detached=t->detached;
    pthread_cond_broadcast(&t->changed);pthread_mutex_unlock(&t->lock);
    if(detached)warm_task_free(t);
    return NULL;
}
static int64_t warm_task_spawn(uint8_t (*entry)(void *),void *data,void *result,int64_t core) {
    // macOS has no API for pinning a thread to a particular CPU.
    if(core < -1 || core >= sysconf(_SC_NPROCESSORS_ONLN))return -12;
    if(core>=0)return -1;
    WarmHostTask *t=host_calloc(sizeof(*t),NULL);
    t->entry=entry;t->data=data;t->result=result;t->message="Task aborted";
    pthread_mutex_init(&t->lock,NULL);pthread_cond_init(&t->changed,NULL);
    if(pthread_create(&t->thread,NULL,warm_task_entry,t)) {
        pthread_cond_destroy(&t->changed);pthread_mutex_destroy(&t->lock);host_free(t);return -1;
    }
    return (intptr_t)t;
}
static int64_t warm_task_wait(WarmHostTask *t) {
    pthread_mutex_lock(&t->lock);
    while(!t->state)pthread_cond_wait(&t->changed,&t->lock);
    int64_t state=t->state;pthread_mutex_unlock(&t->lock);
    pthread_join(t->thread,NULL);return state;
}
static void *warm_task_result(WarmHostTask *t) {return t->result;}
static const char *warm_task_message(WarmHostTask *t) {return t->message;}
static void warm_task_release(WarmHostTask *t) {warm_task_free(t);}
static void warm_task_detach(WarmHostTask *t) {
    pthread_mutex_lock(&t->lock);pthread_detach(t->thread);t->detached=1;
    int done=t->state;pthread_mutex_unlock(&t->lock);
    if(done)warm_task_free(t);
}
static int64_t warm_task_abort(const char *message) {
    if(!warm_current_task)return 0;
    warm_current_task->message=message;
    longjmp(warm_current_task->abort_context,1);
}
static int64_t warm_unix_now(void) {return time(NULL);}
static int64_t warm_monotonic_ms(void) {
    struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);
    return (int64_t)t.tv_sec*1000+t.tv_nsec/1000000;
}
static int64_t warm_sleep(int64_t ms) {
    if(ms<0)return -12;
    struct timespec t={.tv_sec=ms/1000,.tv_nsec=(ms%1000)*1000000};
    return nanosleep(&t,NULL)?warm_net_error():0;
}
static int64_t warm_yield(void) {sched_yield();return 0;}
