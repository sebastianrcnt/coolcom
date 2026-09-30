// Confined OS.Dir IO. Walk each component with openat/O_NOFOLLOW, then operate
// relative to the retained parent descriptor. Never reopen a checked path by name.
static int64_t warm_file_error(void) {
    if (errno == ELOOP || errno == ENOTDIR) return -13;
    return host_io_error();
}
static int warm_file_parent(const char *path, char leaf[PATH_MAX]) {
    if (!path || path[0] != '/' || strlen(path) >= PATH_MAX) {errno=EINVAL;return -1;}
    char copy[PATH_MAX];strcpy(copy,path);
    size_t n=strlen(copy);while(n>1 && copy[n-1]=='/')copy[--n]=0;
    char *last=strrchr(copy,'/');strcpy(leaf,last[1]?last+1:".");*last=0;
    int fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    if(fd<0)return -1;
    char *save=NULL;
    for(char *part=strtok_r(copy,"/",&save);part;part=strtok_r(NULL,"/",&save)) {
        if(!strcmp(part,".")||!strcmp(part,"..")){close(fd);errno=EINVAL;return -1;}
        int next=openat(fd,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        int e=errno;close(fd);if(next<0){errno=e;return -1;}fd=next;
    }
    return fd;
}
static int64_t warm_file_stat(const char *path) {
    char leaf[PATH_MAX];int fd=warm_file_parent(path,leaf);if(fd<0)return warm_file_error();
    struct stat st;int r=fstatat(fd,leaf,&st,AT_SYMLINK_NOFOLLOW);int e=errno;close(fd);errno=e;
    if(r)return errno==ENOENT?0:warm_file_error();
    if(S_ISLNK(st.st_mode))return -13;
    return S_ISDIR(st.st_mode)?2:S_ISREG(st.st_mode)?1:-13;
}
typedef struct {char *data;int64_t size,error;} WarmFileBytes;
static WarmFileBytes *warm_file_read(const char *path) {
    WarmFileBytes *b=host_calloc(sizeof(*b),NULL);char leaf[PATH_MAX];
    int parent=warm_file_parent(path,leaf),fd=-1;
    if(parent>=0){fd=openat(parent,leaf,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);int e=errno;close(parent);errno=e;}
    if(fd<0){b->error=warm_file_error();return b;}
    struct stat st;if(fstat(fd,&st)||!S_ISREG(st.st_mode)){b->error=-13;close(fd);return b;}
    if(st.st_size<0||st.st_size>0x10000000){b->error=-14;close(fd);return b;}
    b->data=host_calloc(st.st_size+1,NULL);b->size=st.st_size;int64_t done=0;
    while(done<b->size){ssize_t n=read(fd,b->data+done,b->size-done);if(n<0&&errno==EINTR)continue;if(n<=0){b->error=n<0?warm_file_error():-1;break;}done+=n;}
    close(fd);return b;
}
static int64_t warm_file_write(const char *path,const void *data,uint64_t size,int64_t create) {
    if(size>0x10000000)return -14;
    char leaf[PATH_MAX];int parent=warm_file_parent(path,leaf);if(parent<0)return warm_file_error();
    // Do not truncate until the descriptor has been verified to be a regular file.
    int fd=openat(parent,leaf,O_WRONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC|(create?O_CREAT:0),0644);
    int e=errno;close(parent);errno=e;if(fd<0)return errno==ENOENT&&!create?-13:warm_file_error();
    struct stat st;if(fstat(fd,&st)||!S_ISREG(st.st_mode)){close(fd);return -13;}
    if(ftruncate(fd,0)){int64_t r=warm_file_error();close(fd);return r;}
    uint64_t done=0;int64_t r=0;while(done<size){ssize_t n=write(fd,(char*)data+done,size-done);if(n<0&&errno==EINTR)continue;if(n<=0){r=warm_file_error();break;}done+=n;}
    if(close(fd)&&!r)r=warm_file_error();return r;
}
static int64_t warm_file_delete(const char *path) {
    char leaf[PATH_MAX];int fd=warm_file_parent(path,leaf);if(fd<0)return warm_file_error();
    struct stat st;int64_t r;
    if(fstatat(fd,leaf,&st,AT_SYMLINK_NOFOLLOW))r=warm_file_error();
    else if(S_ISLNK(st.st_mode))r=-13;
    else r=unlinkat(fd,leaf,S_ISDIR(st.st_mode)?AT_REMOVEDIR:0)?warm_file_error():0;
    close(fd);return r;
}
static int64_t warm_file_mkdir(const char *path) {
    char leaf[PATH_MAX];int fd=warm_file_parent(path,leaf);if(fd<0)return warm_file_error();
    int64_t r=mkdirat(fd,leaf,0755)?warm_file_error():0;close(fd);return r;
}
static HostDirEntry *warm_file_list(const char *path,int64_t *error) {
    char leaf[PATH_MAX];int parent=warm_file_parent(path,leaf),fd=-1;
    if(parent>=0){fd=openat(parent,leaf,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);int e=errno;close(parent);errno=e;}
    DIR *dir=fd>=0?fdopendir(fd):NULL;*error=dir?0:warm_file_error();if(!dir){if(fd>=0)close(fd);return NULL;}
    HostDirEntry *head=NULL;struct dirent *entry;
    errno=0;while((entry=readdir(dir))) {
        if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
        struct stat st;if(fstatat(dirfd(dir),entry->d_name,&st,AT_SYMLINK_NOFOLLOW)){*error=warm_file_error();break;}
        HostDirEntry *e=host_calloc(sizeof(*e),NULL);e->name=host_strnew(entry->d_name,NULL);
        e->size=st.st_size;e->is_dir=S_ISDIR(st.st_mode);e->modified=st.st_mtime;e->next=head;head=e;
        errno=0;
    }
    if(errno&&!*error)*error=warm_file_error();closedir(dir);return head;
}
