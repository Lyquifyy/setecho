import {Composition} from 'remotion';
import {DemoGraphics, LowerThird, MetaStack, Pipeline, TitleCard} from './Scenes';
const video = {width: 1920, height: 1080, fps: 30};
export const Root = () => <>
  <Composition id="DemoGraphics" component={DemoGraphics} durationInFrames={840} {...video}/>
  <Composition id="TitleCard" component={TitleCard} durationInFrames={120} {...video}/>
  <Composition id="Pipeline" component={Pipeline} durationInFrames={360} {...video}/>
  <Composition id="MetaStack" component={MetaStack} durationInFrames={210} {...video}/>
  <Composition id="LowerThird" component={LowerThird} durationInFrames={150} {...video}
    defaultProps={{title: 'Hands-free set logging', detail: 'Say it once. Keep your hands on the workout.', preview: false}}/>
</>;
