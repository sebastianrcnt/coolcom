#include "../src/scroll.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    int x,y,total=0,old=0;
    struct scroll_accumulator s={0};
    for(int i=0;i<100;i++) {
        scroll_lines(&s,0,0.2,true,2,false,i>=50,&x,&y);
        total+=y;old+=(int)0.2;
    }
    assert(total==1 && old==0); // remainder survives transition to momentum
    scroll_lines(&s,0,40,true,1,false,false,&x,&y);assert(y==2);
    scroll_lines(&s,0,-40,true,2,false,true,&x,&y);assert(y==-2);
    scroll_lines(&s,0,10,true,2,false,false,&x,&y);assert(y==0);
    scroll_lines(&s,0,0,true,2,true,false,&x,&y);assert(y==0);
    scroll_lines(&s,0,10,true,2,false,false,&x,&y);assert(y==0);
    scroll_lines(&s,0,1,false,2,false,false,&x,&y);assert(y==1);
    total=0;
    for(int i=0;i<100;i++){scroll_lines(&s,-0.25,-0.25,false,1,false,false,&x,&y);total+=y;assert(x==y);}
    assert(total==-25);
    scroll_lines(&s,NAN,INFINITY,false,1,false,false,&x,&y);assert(x==0 && y==0);
    printf("scroll-test: 100 precise 0.2-point events: old=0, normalized=1 line; Retina, momentum, cancellation, signed/horizontal PASS\n");
}
