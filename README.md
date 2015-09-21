# Static Scoremod
##Concept by Newteee, Developed by Breezy  
### An intuitive scoring system that applies static multipliers to temporary health (x1) and permanent health (x1.5 default)
Takes into account permanent health, temporary health, pill consumption and incaps suffered
> ####Health Bonus pool =   
+Permanent health * 1.5 (configurable multiplier)  
+Temporary health * 1 (unit multiplier)   
 * **held temporary health**
 * bonus pool for **avoiding incaps**: 'x' survivors * 2 max incaps * 30 temp hp/incap (240 in 4 player team)   
   - from which a 30 point penalty is deducted for every incap 
 * bonus pool for **preserving pills from the starting set**:  'x' survivors * 50 temp hp/pill = x * 50 (200 in 4 player team)
   - from which a 50 point penalty is deducted for each consumption of a pill 

> ####Commands ('sm' forms are entered into the console)  
> <coop only> sm_setscore/!setscore to set the score  
> sm_scoring/!scoring for information on how the score system works    
> sm_mapinfo/!mapinfo for map distance and multiplier information    
> sm_(bonus/health)/!bonus/!health for the current round's health bonus  
