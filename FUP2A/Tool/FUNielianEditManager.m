//
//  FUNielianEditManager.m
//  FUP2A
//
//  Created by LEE on 8/7/19.
//  Copyright © 2019 L. All rights reserved.
//

#import "FUNielianEditManager.h"

@implementation FUNielianEditManager
static FUNielianEditManager *sharedInstance;
+ (FUNielianEditManager *)sharedInstance
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		
		sharedInstance = [[FUNielianEditManager alloc] init];
		sharedInstance.orignalStateDic = [NSMutableDictionary dictionary];
		sharedInstance.undoStack = [[FUStack alloc]init];
		sharedInstance.redoStack = [[FUStack alloc]init];
		sharedInstance.hadNotEdit = YES;
	});
	return sharedInstance;
}
-(void)undoStackPop:(PopCompleteBlock)completion
{
    self.undo = YES;
    NSObject *obj = self.undoStack.top;
    [self.redoStack push:[self.undoStack pop]];
    [[NSNotificationCenter defaultCenter]postNotificationName:FUNielianEditManagerStackNotEmptyNot object:nil];
    completion(obj,self.undoStack.isEmpty);
    
//	self.undo = YES;
//    NSDictionary * currentConfig = self.undoStack.top;
//	if (self.redoStack.isEmpty) {
//		[self.redoStack push:[self.undoStack pop]];
//		[[NSNotificationCenter defaultCenter]postNotificationName:FUNielianEditManagerStackNotEmptyNot object:nil];
//	}else{
//		[self.redoStack push:[self.undoStack pop]];
//	}
//
//	if (self.undoStack.isEmpty) {
//		completion(self.orignalStateDic,YES);
//	}else{
//		completion(currentConfig,NO);
//	}
}
-(void)redoStackPop:(PopCompleteBlock)completion
{
    self.redo = YES;
    [self.undoStack push:[self.redoStack pop]];
    if (self.redoStack.isEmpty)
    {
        [[NSNotificationCenter defaultCenter]postNotificationName:FUAvatarEditManagerStackNotEmptyNot object:nil];
    }
    NSObject *obj = self.undoStack.top;
    completion(obj,self.redoStack.isEmpty);
	
}
-(void)push:(NSObject *)object{
	if (self.undoStack.top == nil) {
		self.undoStack.top = object;
		[[NSNotificationCenter defaultCenter]postNotificationName:FUNielianEditManagerStackNotEmptyNot object:nil];
	}
    [self.undoStack push:object];
}
// 字典模型数组里面是否包含某个键值
-(BOOL)exsit:(NSString *)key{
  return [self.undoStack exsit:key] || [self.redoStack exsit:key];
}
-(void)clear{
	self.hadNotEdit = YES;
	self.enterEditVC = NO;
	self.undo = NO;
	self.redo = NO;
	[self.orignalStateDic removeAllObjects];
	[self.undoStack clear];
	[self.redoStack clear];
}

@end
