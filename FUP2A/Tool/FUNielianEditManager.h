//
//  FUNielianEditManager.h
//  FUP2A
//
//  Created by LEE on 8/7/19.
//  Copyright © 2019 L. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "FUStack.h"

NS_ASSUME_NONNULL_BEGIN
typedef void (^PopCompleteBlock)(NSDictionary * config,BOOL isEmpty);
// 用于记录编辑avatar的步数
@interface FUNielianEditManager : NSObject
+ (FUNielianEditManager *)sharedInstance;
@property (nonatomic,strong)FUStack *undoStack;
@property (nonatomic,strong)FUStack *redoStack;
@property (nonatomic,strong)NSMutableDictionary * orignalStateDic;
// 当前avatar还没有编辑过
@property (nonatomic,assign)BOOL hadNotEdit;
// 是否在编辑界面
@property (nonatomic,assign)BOOL enterEditVC;
// 撤销
@property (nonatomic,assign)BOOL undo;
// 重做
@property (nonatomic,assign)BOOL redo;

-(void)undoStackPop:(PopCompleteBlock)completion;
-(void)redoStackPop:(PopCompleteBlock)completion;
-(void)push:(NSObject *)object;
// 字典模型数组里面是否包含某个键值
-(BOOL)exsit:(NSString *)key;
-(void)clear;
@end

NS_ASSUME_NONNULL_END
